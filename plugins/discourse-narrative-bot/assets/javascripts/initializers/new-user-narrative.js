import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "new-user-narrative";

function initialize(api) {
  const messageBus = api.container.lookup("service:message-bus");
  const currentUser = api.getCurrentUser();
  const appEvents = api.container.lookup("service:app-events");

  api.modifyClass("component:site-header", {
    pluginId: PLUGIN_ID,
    didInsertElement() {
      this._super(...arguments);
      this.dispatch("header:search-context-trigger", "header");
    },
  });

  api.attachWidgetAction("header", "headerSearchContextTrigger", function () {
    if (this.site.mobileView) {
      this.state.skipSearchContext = false;
    } else {
      this.state.contextEnabled = true;
      this.state.searchContextType = "topic";
    }
  });

  if (messageBus && currentUser) {
    messageBus.subscribe(`/new_user_narrative/tutorial_search`, () => {
      appEvents.trigger("header:search-context-trigger");
    });
  }
}

export default {
  name: "new-user-narrative",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (siteSettings.discourse_narrative_bot_enabled) {
      withPluginApi("0.8.7", initialize);
    }
  },
};
