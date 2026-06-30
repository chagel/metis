import { Controller } from "@hotwired/stimulus";

// Toggles the schedule/event field sections off the trigger select, and
// composes a cron expression from a frequency + time picker (the cron text
// field stays the source of truth and editable for "custom").
export default class extends Controller {
  static targets = ["scheduleSection", "eventSection", "frequency", "time", "cron"];

  connect() {
    this.toggle();
  }

  toggle() {
    const select = this.element.querySelector("[name='routine[trigger_source]']");
    const isSchedule = select.value === "schedule";
    this.scheduleSectionTarget.hidden = !isSchedule;
    this.eventSectionTarget.hidden = isSchedule;
  }

  build() {
    const freq = this.frequencyTarget.value;
    if (freq === "custom") return;

    const [h, m] = (this.timeTarget.value || "09:00").split(":").map((n) => parseInt(n, 10));
    const expr = {
      daily: `${m} ${h} * * *`,
      weekdays: `${m} ${h} * * 1-5`,
      weekly: `${m} ${h} * * 1`,
      hourly: "0 * * * *",
    }[freq];

    if (expr) this.cronTarget.value = expr;
  }
}
