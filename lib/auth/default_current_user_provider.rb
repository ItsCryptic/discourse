# frozen_string_literal: true
require_relative '../route_matcher'

class Auth::DefaultCurrentUserProvider

  CURRENT_USER_KEY ||= "_DISCOURSE_CURRENT_USER"
  API_KEY ||= "api_key"
  API_USERNAME ||= "api_username"
  HEADER_API_KEY ||= "HTTP_API_KEY"
  HEADER_API_USERNAME ||= "HTTP_API_USERNAME"
  HEADER_API_USER_EXTERNAL_ID ||= "HTTP_API_USER_EXTERNAL_ID"
  HEADER_API_USER_ID ||= "HTTP_API_USER_ID"
  PARAMETER_USER_API_KEY ||= "user_api_key"
  USER_API_KEY ||= "HTTP_USER_API_KEY"
  HASHED_USER_API_KEY ||= "_DISCOURSE_HASHED_USER_API_KEY"
  USER_API_CLIENT_ID ||= "HTTP_USER_API_CLIENT_ID"
  API_KEY_ENV ||= "_DISCOURSE_API"
  USER_API_KEY_ENV ||= "_DISCOURSE_USER_API"
  TOKEN_COOKIE ||= ENV['DISCOURSE_TOKEN_COOKIE'] || "_t"
  PATH_INFO ||= "PATH_INFO"
  COOKIE_ATTEMPTS_PER_MIN ||= 10
  BAD_TOKEN ||= "_DISCOURSE_BAD_TOKEN"

  PARAMETER_API_PATTERNS ||= [
    RouteMatcher.new(
      methods: :get,
      actions: [
        "posts#latest",
        "posts#user_posts_feed",
        "groups#posts_feed",
        "groups#mentions_feed",
        "list#user_topics_feed",
        "list#category_feed",
        "topics#feed",
        "badges#show",
        "tags#tag_feed",
        "tags#show",
        *[:latest, :unread, :new, :read, :posted, :bookmarks].map { |f| "list##{f}_feed" },
        *[:all, :yearly, :quarterly, :monthly, :weekly, :daily].map { |p| "list#top_#{p}_feed" },
        *[:latest, :unread, :new, :read, :posted, :bookmarks].map { |f| "tags#show_#{f}" }
      ],
      formats: :rss
    ),
    RouteMatcher.new(
      methods: :get,
      actions: "users#bookmarks",
      formats: :ics
    ),
    RouteMatcher.new(
      methods: :post,
      actions: "admin/email#handle_mail",
      formats: nil
    ),
  ]

  # do all current user initialization here
  def initialize(env)
    @env = env
    @request = Rack::Request.new(env)
  end

  # our current user, return nil if none is found
  def current_user
    return @env[CURRENT_USER_KEY] if @env.key?(CURRENT_USER_KEY)

    # bypass if we have the shared session header
    if shared_key = @env['HTTP_X_SHARED_SESSION_KEY']
      uid = Discourse.redis.get("shared_session_key_#{shared_key}")
      user = nil
      if uid
        user = User.find_by(id: uid.to_i)
      end
      @env[CURRENT_USER_KEY] = user
      return user
    end

    request = @request

    user_api_key = @env[USER_API_KEY]
    api_key = @env[HEADER_API_KEY]

    if !@env.blank? && request[PARAMETER_USER_API_KEY] && api_parameter_allowed?
      user_api_key ||= request[PARAMETER_USER_API_KEY]
    end

    if !@env.blank? && request[API_KEY] && api_parameter_allowed?
      api_key ||= request[API_KEY]
    end

    auth_cookie = request.cookies[TOKEN_COOKIE].presence unless user_api_key || api_key
    if auth_cookie
      begin
        cookie = DiscourseAuthCookie.parse(auth_cookie)
        # the age check here is not super accurate since the
        # maximum_session_age site setting can change after the
        # auth token has been created. skip the check here and a
        # more accurate age check is done in the SQL query when
        # looking up the auth token record
        cookie.validate!(validate_age: false)
      rescue  DiscourseAuthCookie::InvalidCookie
        cookie = nil
      end
    end

    current_user = nil

    if cookie
      limiter = RateLimiter.new(nil, "cookie_auth_#{request.ip}", COOKIE_ATTEMPTS_PER_MIN , 60)

      if limiter.can_perform?
        @user_token = begin
          UserAuthToken.lookup(
            cookie.token,
            seen: true,
            user_agent: @env['HTTP_USER_AGENT'],
            path: @env['REQUEST_PATH'],
            client_ip: @request.ip
          )
        rescue ActiveRecord::ReadOnlyError
          nil
        end

        current_user = @user_token.try(:user)
      end

      if !current_user
        @env[BAD_TOKEN] = true
        begin
          limiter.performed!
        rescue RateLimiter::LimitExceeded
          raise Discourse::InvalidAccess.new(
            'Invalid Access',
            nil,
            delete_cookie: TOKEN_COOKIE
          )
        end
      end
    elsif @env['HTTP_DISCOURSE_LOGGED_IN']
      @env[BAD_TOKEN] = true
    end

    # possible we have an api call, impersonate
    if api_key
      current_user = lookup_api_user(api_key, request)
      if !current_user
        raise Discourse::InvalidAccess.new(
          I18n.t('invalid_api_credentials'),
          nil,
          custom_message: "invalid_api_credentials"
        )
      end
      raise Discourse::InvalidAccess if current_user.suspended? || !current_user.active
      admin_api_key_limiter.performed! if !Rails.env.profile?
      @env[API_KEY_ENV] = true
    end

    # user api key handling
    if user_api_key
      hashed_user_api_key = ApiKey.hash_key(user_api_key)
      @env[HASHED_USER_API_KEY] = hashed_user_api_key

      user_api_key_obj = UserApiKey
        .active
        .with_key(user_api_key)
        .includes(:user, :scopes)
        .first

      raise Discourse::InvalidAccess unless user_api_key_obj

      user_api_key_limiter_60_mins.performed!
      user_api_key_limiter_1_day.performed!

      user_api_key_obj.ensure_allowed!(@env)

      current_user = user_api_key_obj.user
      raise Discourse::InvalidAccess if !current_user
      raise Discourse::InvalidAccess if current_user.suspended? || !current_user.active

      if can_write?
        user_api_key_obj.update_last_used!(@env[USER_API_CLIENT_ID])
      end

      @env[USER_API_KEY_ENV] = true
    end

    # keep this rule here as a safeguard
    # under no conditions to suspended or inactive accounts get current_user
    if current_user && (current_user.suspended? || !current_user.active)
      current_user = nil
    end

    if current_user && should_update_last_seen?
      u = current_user
      ip = request.ip

      Scheduler::Defer.later "Updating Last Seen" do
        u.update_last_seen!
        u.update_ip_address!(ip)
      end
    end

    @env[CURRENT_USER_KEY] = current_user
  end

  def refresh_session(user, session, cookies)
    # if user was not loaded, no point refreshing session
    # it could be an anonymous path, this would add cost
    return if is_api? || !@env.key?(CURRENT_USER_KEY)

    if !is_user_api? && @user_token && @user_token.user == user
      rotated_at = @user_token.rotated_at

      needs_rotation = @user_token.auth_token_seen ? rotated_at < UserAuthToken::ROTATE_TIME.ago : rotated_at < UserAuthToken::URGENT_ROTATE_TIME.ago

      if needs_rotation
        if @user_token.rotate!(user_agent: @env['HTTP_USER_AGENT'],
                               client_ip: @request.ip,
                               path: @env['REQUEST_PATH'])
          cookies[TOKEN_COOKIE] = cookie_hash(@user_token.unhashed_auth_token, user)
          DiscourseEvent.trigger(:user_session_refreshed, user)
        end
      end
    end

    if !user && cookies.key?(TOKEN_COOKIE)
      cookies.delete(TOKEN_COOKIE)
    end
  end

  def log_on_user(user, session, cookies, opts = {})
    @user_token = UserAuthToken.generate!(
      user_id: user.id,
      user_agent: @env['HTTP_USER_AGENT'],
      path: @env['REQUEST_PATH'],
      client_ip: @request.ip,
      staff: user.staff?,
      impersonate: opts[:impersonate])

    cookies[TOKEN_COOKIE] = cookie_hash(@user_token.unhashed_auth_token, user)
    user.unstage!
    make_developer_admin(user)
    enable_bootstrap_mode(user)

    UserAuthToken.enforce_session_count_limit!(user.id)

    @env[CURRENT_USER_KEY] = user
  end

  def cookie_hash(unhashed_auth_token, user)
    cookie = DiscourseAuthCookie.new(
      token: unhashed_auth_token,
      user_id: user.id,
      trust_level: user.trust_level,
      timestamp: Time.zone.now,
      valid_for: SiteSetting.maximum_session_age.hours
    )
    hash = {
      value: cookie.to_text(Rails.application.secret_key_base),
      httponly: true,
      secure: SiteSetting.force_https
    }

    if SiteSetting.persistent_sessions
      hash[:expires] = SiteSetting.maximum_session_age.hours.from_now
    end

    if SiteSetting.same_site_cookies != "Disabled"
      hash[:same_site] = SiteSetting.same_site_cookies
    end

    hash
  end

  def make_developer_admin(user)
    if  user.active? &&
        !user.admin &&
        Rails.configuration.respond_to?(:developer_emails) &&
        Rails.configuration.developer_emails.include?(user.email)
      user.admin = true
      user.save
    end
  end

  def enable_bootstrap_mode(user)
    return if SiteSetting.bootstrap_mode_enabled

    if user.admin && user.last_seen_at.nil? && user.is_singular_admin?
      Jobs.enqueue(:enable_bootstrap_mode, user_id: user.id)
    end
  end

  def log_off_user(session, cookies)
    user = current_user

    if SiteSetting.log_out_strict && user
      user.user_auth_tokens.destroy_all

      if user.admin && defined?(Rack::MiniProfiler)
        # clear the profiling cookie to keep stuff tidy
        cookies.delete("__profilin")
      end

      user.logged_out
    elsif user && @user_token
      @user_token.destroy
    end

    cookies.delete('authentication_data')
    cookies.delete(TOKEN_COOKIE)
  end

  # api has special rights return true if api was detected
  def is_api?
    current_user
    !!(@env[API_KEY_ENV])
  end

  def is_user_api?
    current_user
    !!(@env[USER_API_KEY_ENV])
  end

  def has_auth_cookie?
    cookie_string = @request.cookies[TOKEN_COOKIE]
    return false if cookie_string.nil?
    cookie = DiscourseAuthCookie.parse(cookie_string)
    cookie.validate!
    true
  rescue DiscourseAuthCookie::InvalidAccess
    false
  end

  def should_update_last_seen?
    return false unless can_write?

    api = !!@env[API_KEY_ENV] || !!@env[USER_API_KEY_ENV]

    if @request.xhr? || api
      @env["HTTP_DISCOURSE_PRESENT"] == "true"
    else
      true
    end
  end

  protected

  def lookup_api_user(api_key_value, request)
    if api_key = ApiKey.active.with_key(api_key_value).includes(:user).first
      api_username = header_api_key? ? @env[HEADER_API_USERNAME] : request[API_USERNAME]

      unless api_key.request_allowed?(@env)
        Rails.logger.warn("[Unauthorized API Access] username: #{api_username}, IP address: #{request.ip}")
        return nil
      end

      user =
        if api_key.user
          api_key.user if !api_username || (api_key.user.username_lower == api_username.downcase)
        elsif api_username
          User.find_by(username_lower: api_username.downcase)
        elsif user_id = header_api_key? ? @env[HEADER_API_USER_ID] : request["api_user_id"]
          User.find_by(id: user_id.to_i)
        elsif external_id = header_api_key? ? @env[HEADER_API_USER_EXTERNAL_ID] : request["api_user_external_id"]
          SingleSignOnRecord.find_by(external_id: external_id.to_s).try(:user)
        end

      if user && can_write?
        api_key.update_columns(last_used_at: Time.zone.now)
      end

      user
    end
  end

  private

  def parameter_api_patterns
    PARAMETER_API_PATTERNS + DiscoursePluginRegistry.api_parameter_routes
  end

  # By default we only allow headers for sending API credentials
  # However, in some scenarios it is essential to send them via url parameters
  # so we need to add some exceptions
  def api_parameter_allowed?
    parameter_api_patterns.any? { |p| p.match?(env: @env) }
  end

  def header_api_key?
    !!@env[HEADER_API_KEY]
  end

  def can_write?
    @can_write ||= !Discourse.pg_readonly_mode?
  end

  def admin_api_key_limiter
    return @admin_api_key_limiter if @admin_api_key_limiter

    limit = GlobalSetting.max_admin_api_reqs_per_minute.to_i
    if GlobalSetting.respond_to?(:max_admin_api_reqs_per_key_per_minute)
      Discourse.deprecate("DISCOURSE_MAX_ADMIN_API_REQS_PER_KEY_PER_MINUTE is deprecated. Please use DISCOURSE_MAX_ADMIN_API_REQS_PER_MINUTE")
      limit = [
        GlobalSetting.max_admin_api_reqs_per_key_per_minute.to_i,
        limit
      ].max
    end
    @admin_api_key_limiter = RateLimiter.new(
      nil,
      "admin_api_min",
      limit,
      60,
      error_code: "admin_api_key_rate_limit"
    )
  end

  def user_api_key_limiter_60_mins
    return @user_api_key_limiter_60_mins if @user_api_key_limiter_60_mins

    hashed_user_api_key = @env[HASHED_USER_API_KEY]
    @user_api_key_limiter_60_mins = RateLimiter.new(
      nil,
      "user_api_min_#{hashed_user_api_key}",
      GlobalSetting.max_user_api_reqs_per_minute,
      60,
      error_code: "user_api_key_limiter_60_mins"
    )
  end

  def user_api_key_limiter_1_day
    return @user_api_key_limiter_1_day if @user_api_key_limiter_1_day

    hashed_user_api_key = @env[HASHED_USER_API_KEY]
    @user_api_key_limiter_1_day = RateLimiter.new(
      nil,
      "user_api_day_#{hashed_user_api_key}",
      GlobalSetting.max_user_api_reqs_per_day,
      86400,
      error_code: "user_api_key_limiter_1_day"
    )
  end
end
