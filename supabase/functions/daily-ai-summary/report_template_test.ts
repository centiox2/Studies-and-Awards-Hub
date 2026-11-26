import { generateReport } from "./generate.ts";
import { buildTemplateReport, templateSelection } from "./report_template.ts";

function assert(value: unknown): asserts value {
  if (!value) throw new Error("assertion failed");
}
assert.equal = (actual: unknown, expected: unknown) => {
  if (actual !== expected) {
    throw new Error(`Expected ${expected}, got ${actual}`);
  }
};
assert.deepEqual = (actual: unknown, expected: unknown) =>
  assert.equal(JSON.stringify(actual), JSON.stringify(expected));
assert.match = (value: string, pattern: RegExp) => {
  if (!pattern.test(value)) {
    throw new Error(`Expected ${value} to match ${pattern}`);
  }
};

const snapshot = {
  date: "2026-11-19",
  cutoff_at: "2026-11-19T13:08:00+03:00",
  weekly_tracker: {
    today: 5,
    today_new: 1,
    today_existing: 4,
    month_total: 18,
    month_new: 7,
    month_existing: 11,
  },
  revenue: { currency: "KSh", today_cents: 120050, month_net_cents: 270050 },
  applications: {
    total: 6,
    with_offer: 2,
    with_coe: 1,
    by_status: { "On hold": 2, "Visa Granted": 1, "Awaiting CAS": 3 },
    updates_today: {
      applications_touched: 3,
      statuses_changed: 1,
      coes_logged: 1,
      follow_ups_updated: 3,
    },
  },
  staff: {
    active: 8,
    activity: [{
      name: "Jordan",
      new_clients: 1,
      existing_clients: 4,
      work_items_updated: 0,
      reports_submitted: 1,
      outputs: [{ label: "Interviews booked", count: 2 }],
    }],
  },
  daily_reports: {
    submitted_today: 0,
    today: 0,
    open: 0,
    overdue: 0,
    blocked: 0,
  },
  team_todo: { open: 0 },
  template_facts: {
    week: { start: "2026-11-16", days: 2, new: 2, existing: 6 },
    purposes: [{
      purpose: "Unspecified",
      entries: 1,
      payments: 1,
      refunds: 0,
      gross_cents: 120050,
      refunded_cents: 0,
      net_cents: 120050,
    }],
    status_moves: [{ from: "Awaiting CAS", to: "Visa Granted", count: 1 }],
    assignees: [
      { label: "Jordan", total: 2, updated: 1, statuses: 1, coes: 1 },
      { label: "jordan", total: 2, updated: 1, statuses: 0, coes: 0 },
      { label: "", total: 2, updated: 1, statuses: 0, coes: 0 },
    ],
    milestones: {
      documents_submitted: 0,
      applications_submitted: 0,
      coes_issued: 0,
    },
    reassigned: 1,
    reassignments: [{ from: "", to: "Jordan", count: 1 }],
    shared_done_today: 0,
  },
};

Deno.test("template keeps exact sections, recorded amounts, flags and assignee spelling", () => {
  const output = buildTemplateReport(snapshot, templateSelection(snapshot)!, 0);
  const { quick, detailed, meta } = output.template;
  const headings = (blocks: typeof quick) =>
    blocks.flatMap((block) => block.kind === "heading" ? [block.text] : []);
  assert.deepEqual(headings(quick), [
    "Today at a Glance",
    "Running Totals",
    "Wins Today",
    "Needs Attention",
    "Team Today",
  ]);
  assert.deepEqual(headings(detailed), [
    "1. Summary",
    "2. Needs Attention",
    "3. Pipeline Overview",
    "4. Staff Activity",
    "5. Status Changes Today",
    "6. Milestones and Dates",
    "7. Data Notes",
  ]);
  assert.match(
    meta,
    /Thursday, 19 November 2026 · Data as of 1:08 PM EAT \(Midday snapshot\)/,
  );
  assert.equal(quick.filter((block) => block.kind === "table").length, 2);
  assert(
    !/payment purpose|daily reports|team to-do|Reports submitted|Who Is Handling Applications/i
      .test(JSON.stringify(output).replaceAll("with no purpose recorded", "")),
  );
  assert.match(JSON.stringify(detailed), /KSh 1,200\.50 gross/);
  const staff = detailed.find((block) =>
    block.kind === "table" && block.columns[0] === "Staff member"
  );
  assert(staff?.kind === "table");
  assert.equal(staff.rows[0][0], "Jordan");
  assert.match(JSON.stringify(detailed), /grouped under Jordan/);
  assert.match(JSON.stringify(detailed), /Jordan · Interviews booked: 2/);
  assert.match(output.brief, /KSh 1,200\.50/);
  assert.match(output.brief, /Visa Granted/);
  assert(output.risks.some((risk) => risk.includes("33% of 6")));
});

Deno.test("Gemini selects a recorded movement and receives no staff or payment details", async () => {
  let calls = 0;
  const output = await generateReport({
    model: "gemini-test",
    key: "unit-test",
    snapshot: {
      ...snapshot,
      template_facts: {
        ...snapshot.template_facts,
        status_events: [
          {
            client: "Example Client",
            changed_by: "Example Editor",
            from: "New",
            to: "Awaiting CAS",
            at: "2026-11-19T09:03:00+03:00",
            exact_time: true,
          },
          {
            client: "Example Client",
            changed_by: null,
            from: "Awaiting CAS",
            to: "Visa Granted",
            at: "2026-11-19T12:03:00+03:00",
            exact_time: false,
          },
        ],
      },
    },
  }, async (_, request) => {
    const body = String(request?.body);
    assert(
      !/Jordan|Interviews booked|Unspecified|120050|Example Client|Example Editor/
        .test(
          body,
        ),
    );
    assert.match(body, /Visa Granted/);
    const movement = ++calls === 1 ? 999 : 1;
    return Response.json({
      candidates: [{
        finishReason: "STOP",
        content: { parts: [{ text: JSON.stringify({ movement }) }] },
      }],
    });
  }, async () => {});
  assert.equal(calls, 2);
  assert.match(String(output.brief), /1 application changed status/);
  assert("template" in output);
  const table = (output as ReturnType<typeof buildTemplateReport>).template
    .detailed.find((block) =>
      block.kind === "table" && block.columns[0] === "Time (EAT)"
    );
  assert.match(
    JSON.stringify(
      (output as ReturnType<typeof buildTemplateReport>).template.quick,
    ),
    /2 status changes/,
  );
  assert(table?.kind === "table");
  assert.deepEqual(table.columns, ["Time (EAT)", "Client", "From", "To"]);
  assert(!JSON.stringify(output).includes("Example Editor"));
  assert.deepEqual(table.rows, [
    ["9:03 AM", "Example Client", "New", "Awaiting CAS"],
    [
      "12:03 PM (detected)",
      "Example Client",
      "Awaiting CAS",
      "Visa Granted",
    ],
  ]);
});

Deno.test("an offer-only day uses its recorded milestone without a model request", async () => {
  const output = await generateReport({
    key: "unit-test",
    model: "gemini-test",
    snapshot: {
      ...snapshot,
      applications: {
        ...snapshot.applications,
        updates_today: { offers_logged: 1, applications_touched: 1 },
      },
      template_facts: {
        ...snapshot.template_facts,
        status_moves: [],
        milestones: {},
      },
    },
  }, () => {
    throw new Error("Unexpected Gemini request");
  });
  assert.match(String(output.brief), /1 new offer date logged/);
});
