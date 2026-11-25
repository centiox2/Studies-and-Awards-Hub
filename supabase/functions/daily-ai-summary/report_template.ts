type Data = Record<string, unknown>;
type Block =
  | { kind: "heading" | "label" | "text"; text: string }
  | { kind: "bullets"; items: string[] }
  | { kind: "table"; columns: string[]; rows: string[][]; total?: boolean };

const map = (value: unknown): Data =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as Data
    : {};
const list = (value: unknown): Data[] =>
  Array.isArray(value) ? value.map(map) : [];
const value = (x: unknown) => typeof x === "number" ? x : 0;
const count = (x: unknown) =>
  typeof x === "number" ? x.toLocaleString("en-KE") : "—";
const text = (x: unknown) => typeof x === "string" && x.trim() ? x.trim() : "—";
const plural = (
  amount: number,
  singular: string,
  pluralForm = `${singular}s`,
) => `${count(amount)} ${amount === 1 ? singular : pluralForm}`;
const sum = (rows: Data[], field: string) =>
  rows.reduce((total, row) => total + value(row[field]), 0);
const pairTable = (first: string, second: string, rows: string[][]) =>
  table([first, second], rows);
const table = (columns: string[], rows: string[][], total = false): Block => ({
  kind: "table",
  columns,
  rows: rows.length ? rows : [columns.map(() => "—")],
  total,
});
const heading = (text: string): Block => ({ kind: "heading", text });
const label = (text: string): Block => ({ kind: "label", text });
const line = (text: string): Block => ({ kind: "text", text });
const bullets = (items: string[], empty: string): Block =>
  items.length ? { kind: "bullets", items } : line(empty);

const displayStatus = (status: string) => {
  const match = /^(coe|cas) issued\s*\/\s*done[-, ]+proceed to visa$/i.exec(
    status,
  );
  return match
    ? `${match[1].toUpperCase()} issued / done, proceed to visa`
    : status;
};
const dateAt = (x: unknown) =>
  typeof x === "string" && Number.isFinite(Date.parse(x)) ? new Date(x) : null;
const nairobi = { timeZone: "Africa/Nairobi" } as const;
const dateFormat = new Intl.DateTimeFormat("en-GB", {
  ...nairobi,
  weekday: "long",
  day: "numeric",
  month: "long",
  year: "numeric",
});
const clock = new Intl.DateTimeFormat("en-KE", {
  ...nairobi,
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});
const hour = new Intl.DateTimeFormat("en-GB", {
  ...nairobi,
  hour: "numeric",
  hourCycle: "h23",
});

function normalizedName(name: string) {
  const normalized = name.toLowerCase();
  return normalized === "winne" ? "winnie" : normalized;
}

function assignees(facts: Data, staff: Data[]) {
  const groups = new Map<
    string,
    {
      name: string;
      labels: Set<string>;
      total: number;
      updated: number;
      statuses: number;
      coes: number;
    }
  >();
  for (const row of list(facts.assignees)) {
    const raw = typeof row.label === "string" ? row.label.trim() : "";
    const key = normalizedName(raw);
    const group = groups.get(key) ??
      {
        name: "Unassigned",
        labels: new Set<string>(),
        total: 0,
        updated: 0,
        statuses: 0,
        coes: 0,
      };
    if (raw) {
      group.labels.add(raw);
      if (group.name === "Unassigned" || /^[A-Z]/.test(raw)) group.name = raw;
      if (
        key === "winnie" && (raw === "Winnie" || group.labels.has("Winnie"))
      ) group.name = "Winnie";
    }
    for (const field of ["total", "updated", "statuses", "coes"] as const) {
      group[field] += value(row[field]);
    }
    groups.set(key, group);
  }
  const names = new Map<string, string>();
  for (const [key, group] of groups) if (key) names.set(key, group.name);
  for (const person of staff) {
    const raw = text(person.name);
    groups.get(normalizedName(raw))?.labels.add(raw);
  }
  const rows = [...groups.values()].sort((a, b) =>
    Number(a.name === "Unassigned") - Number(b.name === "Unassigned") ||
    b.total - a.total || a.name.localeCompare(b.name)
  );
  const notes = rows.filter((row) => row.labels.size > 1).map((row) =>
    `${
      [...row.labels].map((name) => `“${name}”`).join(" and ")
    } are grouped under ${row.name}.`
  );
  return { rows, notes, names };
}

export function templateSelection(snapshot: unknown) {
  const source = map(snapshot);
  if (!source.template_facts) return null;
  const facts = map(source.template_facts);
  const updates = map(map(source.applications).updates_today);
  const milestones = map(facts.milestones);
  const moves = list(facts.status_moves);
  const wins: string[] = [];
  for (const row of moves) {
    const to = displayStatus(text(row.to));
    if (
      value(row.count) &&
      /^(visa granted|(COE|CAS) issued( \/ done, proceed to visa)?|offer letter received)$/i
        .test(to)
    ) {
      wins.push(`${plural(value(row.count), "application")} moved to “${to}”.`);
    }
  }
  const movements: string[] = [];
  if (wins.length) movements.push(wins.slice(0, 2).join(" "));
  if (value(updates.statuses_changed)) {
    movements.push(
      `${
        plural(value(updates.statuses_changed), "application")
      } changed status.`,
    );
  }
  if (value(updates.coes_logged) || value(milestones.coes_issued)) {
    const coes = [
      ifCount(updates.coes_logged, "new COE date", "logged"),
      ifCount(milestones.coes_issued, "COE", "dated today"),
    ].filter(Boolean).join(" · ");
    wins.push(`${coes}.`);
    movements.push(`${coes}.`);
  }
  if (value(updates.offers_logged)) {
    const offers = `${
      plural(value(updates.offers_logged), "new offer date")
    } logged.`;
    wins.push(offers);
    movements.push(offers);
  }
  if (value(map(source.weekly_tracker).today_new)) {
    wins.push(
      `${
        plural(value(map(source.weekly_tracker).today_new), "new client")
      } served.`,
    );
  }
  if (value(updates.follow_ups_updated)) {
    movements.push(
      `${
        plural(value(updates.follow_ups_updated), "application")
      } had a follow-up update.`,
    );
  }
  if (!movements.length) {
    movements.push(
      value(updates.applications_touched)
        ? `${
          plural(value(updates.applications_touched), "application")
        } had a logged update.`
        : "No application updates were logged.",
    );
  }
  return { movements, wins: wins.slice(0, 4) };
}

const ifCount = (x: unknown, noun: string, verb: string) =>
  value(x) ? `${plural(value(x), noun)} ${verb}` : "";

export function buildTemplateReport(
  snapshot: unknown,
  selection: NonNullable<ReturnType<typeof templateSelection>>,
  movementIndex: number,
) {
  const data = map(snapshot);
  const facts = map(data.template_facts);
  const clients = map(data.weekly_tracker);
  const revenue = map(data.revenue);
  const applications = map(data.applications);
  const updates = map(applications.updates_today);
  const pipeline = map(applications.by_status);
  const staff = map(data.staff);
  const people = list(staff.activity).filter((person) =>
    value(person.new_clients) > 0 || value(person.existing_clients) > 0 ||
    value(person.work_items_updated) > 0 ||
    list(person.outputs).some((output) => value(output.count) > 0)
  );
  const week = map(facts.week);
  const purposes = list(facts.purposes);
  const milestones = map(facts.milestones);
  const hasStatusEvents = Array.isArray(facts.status_events);
  const statusEvents = list(facts.status_events);
  const handling = assignees(facts, people);
  const reassignments = list(facts.reassignments);
  const nameFor = (x: unknown) =>
    handling.names.get(normalizedName(text(x))) ?? (x ? text(x) : "Unassigned");
  const staffOutputs = people.flatMap((person) => {
    const entries = list(person.outputs).filter((output) =>
      value(output.count) > 0 && text(output.label) !== "—"
    );
    return entries.length
      ? [
        `${nameFor(person.name)} · ${
          entries.map((output) =>
            `${text(output.label)}: ${count(output.count)}`
          ).join(" · ")
        }`,
      ]
      : [];
  });
  const today = dateAt(data.date);
  const cutoff = dateAt(data.cutoff_at);
  const time = cutoff ? `${clock.format(cutoff).toUpperCase()} EAT` : "—";
  const snapshotLabel = cutoff && +hour.format(cutoff) < 17
    ? "Midday snapshot"
    : "Live snapshot";
  const meta = `${
    today ? dateFormat.format(today) : "—"
  } · Data as of ${time} (${snapshotLabel})`;
  const currency =
    text(revenue.currency) === "—" || revenue.currency === "unspecified"
      ? "KSh"
      : text(revenue.currency);
  const money = (cents: unknown) =>
    typeof cents === "number"
      ? `${currency} ${
        (cents / 100).toLocaleString("en-KE", {
          minimumFractionDigits: cents % 100 ? 2 : 0,
          maximumFractionDigits: 2,
        })
      }`
      : "—";
  const payments = sum(purposes, "payments");
  const refunds = sum(purposes, "refunds");
  const unspecified = purposes.find((p) =>
    String(p.purpose).toLowerCase() === "unspecified"
  );
  const total = value(applications.total);
  const share = (part: number) =>
    total > 0 ? `${Math.round(part * 100 / total)}% of ${count(total)}` : "—";
  const unassigned = handling.rows.find((p) => p.name === "Unassigned");
  const heavy = handling.rows.filter((p) =>
    p.name !== "Unassigned" && total > 0 && p.total > total * 0.4
  );
  const hold = value(
    Object.entries(pipeline).find(([key]) => key.toLowerCase() === "on hold")
      ?.[1],
  );
  const stuck = Object.entries(pipeline).filter(([key, amount]) =>
    ["to pay school fees", "to submit gte documents", "to redo ielts"].includes(
      key.toLowerCase(),
    ) && value(amount) > 0
  );
  const flags: string[] = [];
  if (unassigned && total && unassigned.total > 0) {
    flags.push(
      `${count(unassigned.total)} applications are unassigned (${
        share(unassigned.total)
      }).`,
    );
  }
  if (heavy.length) {
    flags.push(
      `${
        heavy.map((p) =>
          `${p.name} has ${count(p.total)} applications (${share(p.total)})`
        ).join(" · ")
      }.`,
    );
  }
  if (value(unspecified?.payments) || refunds) {
    flags.push(
      [
        value(unspecified?.payments)
          ? `${
            plural(value(unspecified?.payments), "payment")
          } with no purpose recorded (${money(unspecified?.gross_cents)})`
          : "",
        refunds
          ? `${plural(refunds, "refund")} recorded (${
            money(sum(purposes, "refunded_cents"))
          })`
          : "",
      ].filter(Boolean).join(" · ") + ".",
    );
  }
  if (hold > total * 0.2) {
    flags.push(`${count(hold)} applications are on hold (${share(hold)}).`);
  }
  if (stuck.length) {
    flags.push(
      `${
        stuck.map(([status, amount]) =>
          `${count(amount)} ${status.toLowerCase()}`
        ).join(" · ")
      }.`,
    );
  }
  if (
    value(updates.follow_ups_updated) >=
      Math.max(10, value(updates.statuses_changed) * 3)
  ) {
    flags.push(
      `${
        count(updates.follow_ups_updated)
      } applications had follow-up updates and ${
        count(updates.statuses_changed)
      } changed status.`,
    );
  }
  const reassigned = reassignments.map((row) =>
    `${nameFor(row.from)} → ${nameFor(row.to)}`
  ).join(" · ");
  const detailedFlags = flags.length > 5
    ? [...flags.slice(0, 4), flags.slice(4).join("\n")]
    : flags;
  const brief = `${count(clients.today)} clients served today (${
    count(clients.today_new)
  } new) and ${money(revenue.today_cents)} in net revenue.\n${
    selection.movements[movementIndex]
  }`;
  const staffCount = `${count(people.length)} of ${count(staff.active)}`;
  const quick: Block[] = [
    heading("Today at a Glance"),
    table(["Clients", "Net Revenue", "Applications Updated"], [
      [
        count(clients.today),
        money(revenue.today_cents),
        count(updates.applications_touched),
      ],
      [
        `${count(clients.today_new)} new · ${
          count(clients.today_existing)
        } existing`,
        `${plural(payments, "payment")} · ${plural(refunds, "refund")}`,
        hasStatusEvents
          ? plural(statusEvents.length, "status change")
          : `${
            plural(value(updates.statuses_changed), "application")
          } changed status`,
      ],
    ]),
    heading("Running Totals"),
    table(["Period", "Clients", "Net Revenue"], [[
      "This week",
      count(value(week.new) + value(week.existing)),
      "—",
    ], [
      "This month",
      count(clients.month_total),
      money(revenue.month_net_cents),
    ]]),
    heading("Wins Today"),
    bullets(selection.wins, "No status wins recorded yet."),
    heading("Needs Attention"),
    bullets(flags.slice(0, 4), "Nothing needs attention."),
    heading("Team Today"),
    line(`${staffCount} staff recorded activity`),
  ];
  const detailed: Block[] = [
    heading("1. Summary"),
    pairTable("Measure", "Today", [
      [
        "Clients served",
        `${count(clients.today)} (${count(clients.today_new)} new, ${
          count(clients.today_existing)
        } existing)`,
      ],
      ["Net revenue", money(revenue.today_cents)],
      [
        "Revenue details",
        [
          `${plural(payments, "payment")} · ${plural(refunds, "refund")}`,
          `${money(sum(purposes, "gross_cents"))} gross · ${
            money(sum(purposes, "refunded_cents"))
          } refunded`,
          `${money(revenue.month_net_cents)} month to date`,
        ].join("\n"),
      ],
      ["Applications with logged updates", count(updates.applications_touched)],
      ["Staff with recorded activity", staffCount],
    ]),
    heading("2. Needs Attention"),
    bullets(detailedFlags, "Nothing needs attention."),
    heading("3. Pipeline Overview"),
    line(
      `${count(applications.total)} applications in the tracker · ${
        count(applications.with_offer)
      } with an offer date · ${count(applications.with_coe)} with a COE date`,
    ),
    pairTable(
      "Status",
      "Applications",
      Object.entries(pipeline).sort((a, b) =>
        value(b[1]) - value(a[1]) || a[0].localeCompare(b[0])
      ).map(([status, amount]) => [displayStatus(status), count(amount)]),
    ),
    heading("4. Staff Activity"),
    table(
      [
        "Staff member",
        "New",
        "Existing",
        "Total clients",
        "Work items updated",
      ],
      people.map((
        person,
      ) => [
        nameFor(person.name),
        count(person.new_clients),
        count(person.existing_clients),
        count(value(person.new_clients) + value(person.existing_clients)),
        count(person.work_items_updated),
      ]),
    ),
    ...(staffOutputs.length
      ? [label("Reported outputs"), {
        kind: "bullets" as const,
        items: staffOutputs,
      }]
      : []),
    line(
      "Activity is based on recorded client counts and work updates.",
    ),
    heading("5. Status Changes Today"),
    label(
      `Status changes (${
        count(hasStatusEvents ? statusEvents.length : updates.statuses_changed)
      })`,
    ),
    hasStatusEvents
      ? table(
        ["Time (EAT)", "Client", "From", "To"],
        statusEvents.map((event) => {
          const at = dateAt(event.at);
          return [
            at
              ? `${clock.format(at).toUpperCase()}${
                event.exact_time === true ? "" : " (detected)"
              }`
              : "—",
            text(event.client),
            displayStatus(text(event.from)),
            displayStatus(text(event.to)),
          ];
        }),
      )
      : pairTable(
        "From",
        "To",
        list(facts.status_moves).map((
          row,
        ) => [
          displayStatus(text(row.from)),
          `${displayStatus(text(row.to))}${
            value(row.count) > 1 ? ` (${count(row.count)})` : ""
          }`,
        ]),
      ),
    ...(statusEvents.some((event) => event.exact_time !== true)
      ? [
        line(
          "When Airtable lacks an edit time, the table shows when S&A Hub detected the change.",
        ),
      ]
      : []),
    heading("6. Milestones and Dates"),
    pairTable("Item", "Applications", [
      ["COE dates newly logged", count(updates.coes_logged)],
      ["COE issued (dated today)", count(milestones.coes_issued)],
      ["New offer dates logged", count(updates.offers_logged)],
      ["Documents submitted", count(milestones.documents_submitted)],
      ["Applications submitted", count(milestones.applications_submitted)],
      [
        "Applications added / removed",
        `${count(updates.added)} / ${count(updates.removed)}`,
      ],
      [
        "Reassigned",
        `${count(facts.reassigned)}${reassigned ? ` (${reassigned})` : ""}`,
      ],
    ]),
    label("Records updated"),
    pairTable("Update type", "Applications", [
      ["Any logged update", count(updates.applications_touched)],
      ["Follow-up updates", count(updates.follow_ups_updated)],
      ["Status changed", count(updates.statuses_changed)],
    ]),
    heading("7. Data Notes"),
    bullets(
      [
        `${snapshotLabel} at ${time}. Figures reflect records available at the cutoff.`,
        ...handling.notes,
        ...(value(unspecified?.payments)
          ? [
            `${
              plural(value(unspecified?.payments), "payment")
            } with no purpose recorded.`,
          ]
          : []),
        ...(value(updates.coes_logged)
          ? [
            "Newly logged COE dates may refer to documents issued on an earlier date.",
          ]
          : []),
      ].slice(0, 5),
      "—",
    ),
  ];
  const legacyPages = [
    [1, "weekly_tracker"],
    [3, "applications"],
    [4, "staff"],
  ] as const;
  const legacy = legacyPages.map(([index, page]) => {
    const start = detailed.findIndex((block) =>
      block.kind === "heading" && block.text.startsWith(`${index}. `)
    );
    const title = (detailed[start] as { text: string }).text.replace(
      /^\d+\. /,
      "",
    );
    const body: string[] = [];
    for (const block of detailed.slice(start + 1)) {
      if (block.kind === "heading") break;
      if (block.kind === "text") body.push(block.text);
      if (block.kind === "table") {
        // This legacy summary remains compact. The full event table is shown
        // in the template view, including repeated changes for one client.
        if (block.columns[0] === "Time (EAT)") continue;
        body.push(...block.rows.slice(0, 6).map((row) => row.join(" · ")));
      }
    }
    return {
      page,
      title,
      body: body.join("\n").slice(0, 3000),
      findings: [],
      next_steps: [],
    };
  });
  return {
    brief,
    highlights: selection.wins,
    risks: flags.slice(0, 5),
    actions: [],
    sections: [
      ...legacy,
      {
        page: "revenue",
        title: "Revenue",
        body: `${money(revenue.today_cents)} net revenue today · ${
          money(revenue.month_net_cents)
        } month to date`,
        findings: [],
        next_steps: [],
      },
    ],
    template: { version: 1, meta, quick, detailed },
  };
}
