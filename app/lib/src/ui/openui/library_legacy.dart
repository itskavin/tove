// The first Tove OpenUI component set (tove 552671d…607c503, 2026-11-18):
// Tove's own names (Stack root, Title, Facts, Stats, Entities…). Kept so
// replies written with it still render; the prompt now teaches the official
// OpenUI chat library (library.dart).

import 'library.dart' show OuiComponent, OuiProp;

const _tones = ['neutral', 'good', 'warn', 'bad', 'info'];
const _states = ['ok', 'warn', 'bad', 'info', 'unknown'];

/// The round-9 Tove component set (root `Stack`). Replies written for it
/// still render; the prompt no longer teaches it.
const List<OuiComponent> legacyComponents = [
  // Layout
  OuiComponent('Stack', 'Layout', 'Vertical column; the root.', [
    OuiProp('children', 'Node[]', required: true),
    OuiProp('gap', 'string', values: ['sm', 'md', 'lg']),
  ]),
  OuiComponent('Row', 'Layout', 'Items side by side; wraps when narrow.', [
    OuiProp('children', 'Node[]', required: true),
  ]),
  OuiComponent(
    'Grid',
    'Layout',
    'Equal columns (default 2; fewer on narrow screens).',
    [
      OuiProp('children', 'Node[]', required: true),
      OuiProp('columns', 'number'),
    ],
  ),
  OuiComponent(
    'Card',
    'Layout',
    'Outlined card; image is a cover picture URL.',
    [
      OuiProp('children', 'Node[]', required: true),
      OuiProp('title', 'text'),
      OuiProp('image', 'string'),
      OuiProp('subtitle', 'text'),
    ],
  ),
  OuiComponent(
    'Carousel',
    'Layout',
    'Horizontal scroller of cards or pictures.',
    [OuiProp('children', 'Node[]', required: true)],
  ),
  OuiComponent(
    'Tabs',
    'Layout',
    'One pane at a time; days of a trip, options.',
    [OuiProp('items', 'Tab[]', required: true)],
  ),
  OuiComponent('Tab', 'Layout', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('children', 'Node[]', required: true),
  ]),
  OuiComponent('Accordion', 'Layout', 'Collapsible sections.', [
    OuiProp('items', 'Panel[]', required: true),
  ]),
  OuiComponent('Panel', 'Layout', '', [
    OuiProp('title', 'text', required: true),
    OuiProp('children', 'Node[]', required: true),
    OuiProp('open', 'boolean'),
  ]),
  OuiComponent('Separator', 'Layout', 'Thin rule.', []),
  // Content
  OuiComponent('Title', 'Content', 'Heading.', [
    OuiProp('text', 'text', required: true),
    OuiProp('size', 'string', values: ['sm', 'md', 'lg']),
  ]),
  OuiComponent(
    'Text',
    'Content',
    'Paragraph; inline **bold**, *italic*, [links](url).',
    [
      OuiProp('text', 'text', required: true),
      OuiProp('tone', 'string', values: ['default', 'muted']),
    ],
  ),
  OuiComponent(
    'Markdown',
    'Content',
    'Longer prose: lists, headings, tables.',
    [OuiProp('text', 'string', required: true)],
  ),
  OuiComponent('Callout', 'Content', 'Highlighted note.', [
    OuiProp('text', 'text', required: true),
    OuiProp(
      'tone',
      'string',
      values: ['info', 'tip', 'warning', 'danger', 'success'],
    ),
    OuiProp('title', 'text'),
  ]),
  OuiComponent('Badge', 'Content', 'Small outlined label.', [
    OuiProp('text', 'text', required: true),
    OuiProp('tone', 'string', values: _tones),
  ]),
  OuiComponent('List', 'Content', 'Bullet or numbered list.', [
    OuiProp('items', 'string[]', required: true),
    OuiProp('numbered', 'boolean'),
  ]),
  OuiComponent(
    'Steps',
    'Content',
    'Timeline: recipe steps, itinerary, how-to.',
    [OuiProp('items', 'Step[]', required: true)],
  ),
  OuiComponent('Step', 'Content', '', [
    OuiProp('title', 'text', required: true),
    OuiProp('body', 'text'),
    OuiProp('time', 'text'),
  ]),
  OuiComponent('Table', 'Content', 'Data table.', [
    OuiProp('columns', 'string[]', required: true),
    OuiProp('rows', 'rows', required: true),
  ]),
  OuiComponent('Facts', 'Content', 'Spec sheet of label/value rows.', [
    OuiProp('items', 'Fact[]', required: true),
  ]),
  OuiComponent('Fact', 'Content', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('value', 'text', required: true),
  ]),
  OuiComponent('ProsCons', 'Content', '', [
    OuiProp('pros', 'string[]', required: true),
    OuiProp('cons', 'string[]', required: true),
  ]),
  OuiComponent('Code', 'Content', 'Code block with copy.', [
    OuiProp('code', 'string', required: true),
    OuiProp('language', 'string'),
  ]),
  OuiComponent('Link', 'Content', 'Link (opens after a confirm).', [
    OuiProp('text', 'text', required: true),
    OuiProp('url', 'string', required: true),
  ]),
  // Data
  OuiComponent('Stats', 'Data', 'Up to 4 big numbers.', [
    OuiProp('items', 'Stat[]', required: true),
  ]),
  OuiComponent('Stat', 'Data', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('value', 'text', required: true),
    OuiProp('sub', 'text'),
    OuiProp('tone', 'string', values: _tones),
  ]),
  OuiComponent('Metrics', 'Data', 'Metric rows with optional trend line.', [
    OuiProp('items', 'Metric[]', required: true),
  ]),
  OuiComponent('Metric', 'Data', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('value', 'text', required: true),
    OuiProp('unit', 'string'),
    OuiProp('delta', 'text'),
    OuiProp('tone', 'string', values: _tones),
    OuiProp('trend', 'number[]'),
  ]),
  OuiComponent('Gauges', 'Data', 'Rings for usage (CPU, disk).', [
    OuiProp('items', 'Gauge[]', required: true),
  ]),
  OuiComponent('Gauge', 'Data', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('value', 'number', required: true),
    OuiProp('max', 'number'),
    OuiProp('unit', 'string'),
    OuiProp('tone', 'string', values: _tones),
  ]),
  OuiComponent('Progress', 'Data', 'Labelled bar.', [
    OuiProp('label', 'text', required: true),
    OuiProp('value', 'number', required: true),
    OuiProp('max', 'number'),
  ]),
  OuiComponent('Status', 'Data', 'Overall health line.', [
    OuiProp('title', 'text', required: true),
    OuiProp('state', 'string', values: _states),
    OuiProp('summary', 'text'),
    OuiProp('updated', 'text'),
  ]),
  OuiComponent('Services', 'Data', 'Service rows; a tap asks about one.', [
    OuiProp('items', 'Service[]', required: true),
    OuiProp('title', 'text'),
  ]),
  OuiComponent('Service', 'Data', '', [
    OuiProp('name', 'text', required: true),
    OuiProp('state', 'string', values: _states),
    OuiProp('latency', 'text'),
    OuiProp('sub', 'text'),
  ]),
  OuiComponent('Alerts', 'Data', '', [
    OuiProp('items', 'Alert[]', required: true),
  ]),
  OuiComponent('Alert', 'Data', '', [
    OuiProp('title', 'text', required: true),
    OuiProp('tone', 'string', values: _tones),
    OuiProp('body', 'text'),
    OuiProp('time', 'text'),
  ]),
  OuiComponent('Chart', 'Data', 'Line or bar chart.', [
    OuiProp('kind', 'string', required: true, values: ['line', 'bar']),
    OuiProp('labels', 'string[]', required: true),
    OuiProp('series', 'Series[]', required: true),
    OuiProp('title', 'text'),
    OuiProp('unit', 'string'),
  ]),
  OuiComponent('Series', 'Data', '', [
    OuiProp('name', 'text', required: true),
    OuiProp('values', 'number[]', required: true),
  ]),
  // Media
  OuiComponent('Image', 'Media', 'A picture.', [
    OuiProp('src', 'string', required: true),
    OuiProp('alt', 'text'),
  ]),
  OuiComponent('Gallery', 'Media', 'Several pictures.', [
    OuiProp('images', 'string[]', required: true),
  ]),
  OuiComponent(
    'Entities',
    'Media',
    'Picture cards for people, places, products; tap = more.',
    [OuiProp('items', 'Entity[]', required: true)],
  ),
  OuiComponent('Entity', 'Media', '', [
    OuiProp('name', 'text', required: true),
    OuiProp('sub', 'text'),
    OuiProp('image', 'string'),
    OuiProp('about', 'text'),
  ]),
  OuiComponent('News', 'Media', 'Article rows.', [
    OuiProp('items', 'Article[]', required: true),
  ]),
  OuiComponent('Article', 'Media', '', [
    OuiProp('title', 'text', required: true),
    OuiProp('url', 'string', required: true),
    OuiProp('source', 'text'),
    OuiProp('date', 'text'),
    OuiProp('image', 'string'),
  ]),
  // Interaction
  OuiComponent('Buttons', 'Interaction', 'Button row.', [
    OuiProp('items', 'Button[]', required: true),
  ]),
  OuiComponent('Button', 'Interaction', 'No action = sends its label.', [
    OuiProp('label', 'text', required: true),
    OuiProp('action', 'action'),
    OuiProp('primary', 'boolean'),
  ]),
  OuiComponent(
    'Options',
    'Interaction',
    'Choice chips; a tap sends the choice.',
    [OuiProp('items', 'string[]', required: true), OuiProp('prompt', 'text')],
  ),
  OuiComponent(
    'Checklist',
    'Interaction',
    'Tickable task list (ticks are saved).',
    [OuiProp('items', 'string[]', required: true), OuiProp('title', 'text')],
  ),
  OuiComponent('Input', 'Interaction', '', [
    OuiProp('value', 'string', required: true, bindable: true),
    OuiProp('label', 'text'),
    OuiProp('placeholder', 'text'),
  ]),
  OuiComponent('Slider', 'Interaction', '', [
    OuiProp('value', 'number', required: true, bindable: true),
    OuiProp('label', 'text', required: true),
    OuiProp('min', 'number', required: true),
    OuiProp('max', 'number', required: true),
    OuiProp('step', 'number'),
    OuiProp('unit', 'string'),
  ]),
  OuiComponent('Toggle', 'Interaction', '', [
    OuiProp('value', 'boolean', required: true, bindable: true),
    OuiProp('label', 'text', required: true),
  ]),
  OuiComponent('Select', 'Interaction', 'Pick one; local, nothing is sent.', [
    OuiProp('value', 'string', required: true, bindable: true),
    OuiProp('options', 'string[]', required: true),
    OuiProp('label', 'text'),
  ]),
];
