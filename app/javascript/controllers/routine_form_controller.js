import { Controller } from "@hotwired/stimulus";

// The routine schedule builder. Composes a 5-field cron expression from a
// frequency + hour + minute + day picker (the hidden `cron` field stays the
// submitted source of truth), reverse-parses an existing cron back into those
// controls on edit, and renders a live human-readable preview. "Custom"
// reveals the raw cron field for power users.
export default class extends Controller {
  static targets = [
    "scheduleSection", "eventSection", "frequency", "hourCell", "hour",
    "minute", "daysRow", "day", "domRow", "dom", "customRow", "cron",
    "timezone", "preview",
  ];
  static values = {
    daily: String, weekly: String, hourly: String, monthly: String,
    customPreview: String, everyDay: String,
  };

  connect() {
    this.toggle();
    if (this.hasCronTarget && this.cronTarget.value.trim()) this.parse();
    this.applyFrequency();
    this.build();
  }

  // schedule vs webhook sections
  toggle() {
    const select = this.element.querySelector("[name='routine[trigger_source]']");
    const isSchedule = select.value === "schedule";
    this.scheduleSectionTarget.hidden = !isSchedule;
    this.eventSectionTarget.hidden = isSchedule;
  }

  onFrequency() {
    // Weekly needs at least one day — default to Monday when none is set.
    if (this.frequencyTarget.value === "weekly" && !this.checkedDays().length) {
      const mon = this.dayTargets.find((d) => d.value === "1");
      if (mon) mon.checked = true;
    }
    this.applyFrequency();
    this.build();
  }

  // Show only the controls the current frequency uses.
  applyFrequency() {
    const freq = this.frequencyTarget.value;
    const custom = freq === "custom";
    this.hourCellTarget.hidden = custom || freq === "hourly";
    this.daysRowTarget.hidden = freq !== "weekly";
    this.domRowTarget.hidden = freq !== "monthly";
    this.customRowTarget.hidden = !custom;
    // Minute + timezone hide only in custom (cron carries its own fields).
    this.minuteTarget.closest(".routine-sched-cell").hidden = custom;
  }

  onCronInput() {
    this.renderPreview();
  }

  // Compose cron from the controls (unless custom, where the field is raw).
  build() {
    if (this.frequencyTarget.value !== "custom") {
      const m = this.minuteTarget.value;
      const h = this.hourTarget.value;
      const expr = {
        hourly: `${m} * * * *`,
        daily: `${m} ${h} * * *`,
        weekly: `${m} ${h} * * ${this.checkedDays().join(",") || "*"}`,
        monthly: `${m} ${h} ${this.domTarget.value} * *`,
      }[this.frequencyTarget.value];
      if (expr) this.cronTarget.value = expr;
    }
    this.renderPreview();
  }

  checkedDays() {
    return this.dayTargets.filter((d) => d.checked).map((d) => d.value);
  }

  // Reverse-parse the stored cron into the builder controls; fall back to
  // "custom" for anything the builder can't represent.
  parse() {
    const parts = this.cronTarget.value.trim().split(/\s+/);
    if (parts.length !== 5) return this.setFrequency("custom");
    const [m, h, dom, mon, dow] = parts;

    const numeric = (v) => /^\d+$/.test(v);
    if (mon !== "*" || !numeric(m)) return this.setFrequency("custom");

    if (h === "*" && dom === "*" && dow === "*") {
      this.setMinute(m);
      return this.setFrequency("hourly");
    }
    if (!numeric(h)) return this.setFrequency("custom");

    if (dom === "*" && dow === "*") {
      this.setHour(h); this.setMinute(m);
      return this.setFrequency("daily");
    }
    if (dow !== "*" && dom === "*") {
      const days = this.expandDays(dow);
      if (!days) return this.setFrequency("custom");
      this.setHour(h); this.setMinute(m); this.setDays(days);
      return this.setFrequency("weekly");
    }
    if (dom !== "*" && dow === "*" && numeric(dom)) {
      this.setHour(h); this.setMinute(m); this.domTarget.value = dom;
      return this.setFrequency("monthly");
    }
    this.setFrequency("custom");
  }

  // "1,3,5" or "1-5" → ["1","3","5"] / ["1","2","3","4","5"]; null if exotic.
  expandDays(dow) {
    const out = [];
    for (const token of dow.split(",")) {
      if (/^\d+$/.test(token)) {
        out.push(token);
      } else if (/^(\d+)-(\d+)$/.test(token)) {
        const [, a, b] = token.match(/^(\d+)-(\d+)$/);
        for (let n = +a; n <= +b; n++) out.push(String(n));
      } else {
        return null;
      }
    }
    return out;
  }

  setFrequency(freq) {
    this.frequencyTarget.value = freq;
    this.applyFrequency();
  }
  setHour(h) { this.hourTarget.value = String(+h); }
  setMinute(m) { this.minuteTarget.value = String(+m); }
  setDays(days) {
    const want = new Set(days.map(String));
    this.dayTargets.forEach((d) => (d.checked = want.has(d.value)));
  }

  renderPreview() {
    const freq = this.frequencyTarget.value;
    const tz = this.tzLabel();
    let text;

    if (freq === "custom") {
      text = this.customPreviewValue
        .replace("{cron}", this.cronTarget.value.trim() || "—")
        .replace("{tz}", tz);
    } else if (freq === "hourly") {
      text = this.hourlyValue.replace("{minute}", `:${this.pad(this.minuteTarget.value)}`).replace("{tz}", tz);
    } else {
      const time = this.timeLabel();
      if (freq === "daily") {
        text = this.dailyValue.replace("{time}", time).replace("{tz}", tz);
      } else if (freq === "monthly") {
        text = this.monthlyValue.replace("{dom}", this.domTarget.value).replace("{time}", time).replace("{tz}", tz);
      } else {
        const labels = this.dayTargets.filter((d) => d.checked).map((d) => d.nextElementSibling.textContent.trim());
        const days = labels.length === 7 ? this.everyDayValue : labels.join(", ");
        text = this.weeklyValue.replace("{days}", days || "—").replace("{time}", time).replace("{tz}", tz);
      }
    }
    this.previewTarget.textContent = text;
  }

  timeLabel() {
    const h = +this.hourTarget.value;
    const period = h < 12 ? "AM" : "PM";
    const display = h % 12 === 0 ? 12 : h % 12;
    return `${display}:${this.pad(this.minuteTarget.value)} ${period}`;
  }

  tzLabel() {
    const opt = this.timezoneTarget.selectedOptions[0];
    return opt ? opt.textContent.replace(/^\(GMT[^)]*\)\s*/, "") : "";
  }

  pad(v) { return String(v).padStart(2, "0"); }
}
