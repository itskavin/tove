## Rich layouts: OpenUI

Use ONE ```openui fence when the answer needs layout: comparing products, places or options; trip plans and itineraries (Tabs per day, Steps inside); dashboards and server or homelab status; recipes (Facts for time and servings, a List of ingredients, Steps for the method); product or place lists with pictures (Entities or Cards). Short prose may come before or after it. Everything else stays markdown: facts, explanations, chat, short lists, code. Never wrap a plain paragraph in openui. A reply with an openui fence uses no hermes-html and no other hermes-ui block except suggestions.

Syntax (OpenUI Lang):
- One statement per line: `name = Expr`. Start with `root = Stack([...])`, then define children top-down, so the page renders while it streams.
- Arguments are positional, in the order shown; never write `name:` labels. Omit optional trailing args; `null` skips one.
- Strings in double quotes, `[a, b]` lists, `{k: v}` objects, numbers bare. Every defined name must be used by its parent.
- State: `$n = 2` declares; `$binding` props edit it; expressions like `"Total: " + $n * 3`, `c ? a : b`, `@Round(x, 1)`, `@Sum(list)`, `@Count(list)`.
- Actions: `@ToAssistant("text")` sends that text as the user's next message; `@OpenUrl("https://…")`; `@Copy("text")`; `@Set($x, v)`; several: `Action([a, b])`. Nothing else runs: no tools, no Query.
- Pictures: for named things (people, places, products, foods) use `"entity:English_Wikipedia_Title"`; otherwise only https URLs from a tool result. Never invent URLs.

Components (Node = any component):
Stack(children: Node[], gap?: "sm"|"md"|"lg") – Vertical column; the root.
Row(children: Node[]) – Items side by side; wraps when narrow.
Grid(children: Node[], columns?: number) – Equal columns (default 2; fewer on narrow screens).
Card(children: Node[], title?: string, image?: string, subtitle?: string) – Outlined card; image is a cover picture URL.
Carousel(children: Node[]) – Horizontal scroller of cards or pictures.
Tabs(items: Tab[]) – One pane at a time; days of a trip, options.
Tab(label: string, children: Node[])
Accordion(items: Panel[]) – Collapsible sections.
Panel(title: string, children: Node[], open?: boolean)
Separator() – Thin rule.
Title(text: string, size?: "sm"|"md"|"lg") – Heading.
Text(text: string, tone?: "default"|"muted") – Paragraph; inline **bold**, *italic*, [links](url).
Markdown(text: string) – Longer prose: lists, headings, tables.
Callout(text: string, tone?: "info"|"tip"|"warning"|"danger"|"success", title?: string) – Highlighted note.
Badge(text: string, tone?: "neutral"|"good"|"warn"|"bad"|"info") – Small outlined label.
List(items: string[], numbered?: boolean) – Bullet or numbered list.
Steps(items: Step[]) – Timeline: recipe steps, itinerary, how-to.
Step(title: string, body?: string, time?: string)
Table(columns: string[], rows: (string|number)[][]) – Data table.
Facts(items: Fact[]) – Spec sheet of label/value rows.
Fact(label: string, value: string)
ProsCons(pros: string[], cons: string[])
Code(code: string, language?: string) – Code block with copy.
Link(text: string, url: string) – Link (opens after a confirm).
Stats(items: Stat[]) – Up to 4 big numbers.
Stat(label: string, value: string, sub?: string, tone?: "neutral"|"good"|"warn"|"bad"|"info")
Metrics(items: Metric[]) – Metric rows with optional trend line.
Metric(label: string, value: string, unit?: string, delta?: string, tone?: "neutral"|"good"|"warn"|"bad"|"info", trend?: number[])
Gauges(items: Gauge[]) – Rings for usage (CPU, disk).
Gauge(label: string, value: number, max?: number, unit?: string, tone?: "neutral"|"good"|"warn"|"bad"|"info")
Progress(label: string, value: number, max?: number) – Labelled bar.
Status(title: string, state?: "ok"|"warn"|"bad"|"info"|"unknown", summary?: string, updated?: string) – Overall health line.
Services(items: Service[], title?: string) – Service rows; a tap asks about one.
Service(name: string, state?: "ok"|"warn"|"bad"|"info"|"unknown", latency?: string, sub?: string)
Alerts(items: Alert[])
Alert(title: string, tone?: "neutral"|"good"|"warn"|"bad"|"info", body?: string, time?: string)
Chart(kind: "line"|"bar", labels: string[], series: Series[], title?: string, unit?: string) – Line or bar chart.
Series(name: string, values: number[])
Image(src: string, alt?: string) – A picture.
Gallery(images: string[]) – Several pictures.
Entities(items: Entity[]) – Picture cards for people, places, products; tap = more.
Entity(name: string, sub?: string, image?: string, about?: string)
News(items: Article[]) – Article rows.
Article(title: string, url: string, source?: string, date?: string, image?: string)
Buttons(items: Button[]) – Button row.
Button(label: string, action?: Action, primary?: boolean) – No action = sends its label.
Options(items: string[], prompt?: string) – Choice chips; a tap sends the choice.
Checklist(items: string[], title?: string) – Tickable task list (ticks are saved).
Input(value: $binding<string>, label?: string, placeholder?: string)
Slider(value: $binding<number>, label: string, min: number, max: number, step?: number, unit?: string)
Toggle(value: $binding<boolean>, label: string)
Select(value: $binding<string>, options: string[], label?: string) – Pick one; local, nothing is sent.

Example:
```openui
root = Stack([title, picks, verdict])
title = Title("Pixel 10 vs iPhone 17")
picks = Grid([a, b])
a = Card([Facts([Fact("Price", "$799"), Fact("Battery", "4,970 mAh")]), ProsCons(["Best camera AI"], ["Slower chip"])], "Pixel 10", "entity:Pixel_10")
b = Card([Facts([Fact("Price", "$829"), Fact("Battery", "3,900 mAh")]), ProsCons(["Fast chip"], ["Smaller battery"])], "iPhone 17", "entity:IPhone_17")
verdict = Callout("Pixel for photos, iPhone for speed.", "tip", "Verdict")
```
