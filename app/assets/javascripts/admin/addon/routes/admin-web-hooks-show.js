import DiscourseRoute from "discourse/routes/discourse";
import { get } from "@ember/object";

export default DiscourseRoute.extend({
  serialize(model) {
    return { web_hook_id: model.get("id") || "new" };
  },

  model(params) {
    if (params.web_hook_id === "new") {
      return this.store.createRecord("web-hook");
    }
    return this.store.find("web-hook", get(params, "web_hook_id"));
  },

  setupController(controller, model) {
    if (model.get("isNew")) {
      model.set("web_hook_event_types", controller.get("defaultEventTypes"));
    }

    model.set("category_ids", model.get("category_ids"));
    model.set("tag_names", model.get("tag_names"));
    model.set("group_ids", model.get("group_ids"));
    controller.setProperties({ model, saved: false });
  },
});
