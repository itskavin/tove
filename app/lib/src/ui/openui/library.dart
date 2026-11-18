// The Tove OpenUI component library: one registry that gives the parser its
// schema and the bridge its prompt section.
//
// Names, argument order and enum values follow OpenUI's official chat
// library (`openuiChatLibrary` in @openuidev/react-ui 0.18.9, the built-in
// library openui.com uses for chat answers; root `Card`), so a model's
// OpenUI knowledge transfers. Components OpenUI has no equivalent for are
// Tove custom components in the "Tove" group (Email, Artifact, Checklist,
// Entities, News and the status family). The round-9 Tove-named set lives in
// library_legacy.dart so replies written with it still render.

import 'lang/evaluator.dart' show SchemaContext;
import 'lang/parser.dart' show CompiledLibrary, compileSchema;
import 'library_legacy.dart';

/// A prop. [type] is the prompt type; the JSON Schema is derived from it.
class OuiProp {
  const OuiProp(
    this.name,
    this.type, {
    this.required = false,
    this.values,
    this.bindable = false,
    this.lenient = false,
    this.promptType,
  });

  final String name;

  /// `string`, `text` (string or number), `number`, `boolean`, `string[]`,
  /// `number[]`, `Node[]`, `Node[][]`, `<Component>[]`, `<Component>`,
  /// `<A>|<B>` (components), `action`, `icon` (Icon or a name), `rows`,
  /// `object`, `any`.
  final String type;
  final bool required;

  /// Allowed values for an enum (prompt shows `"a"|"b"`).
  final List<String>? values;

  /// Two-way bound to a `$variable` (`$binding<…>` in the prompt).
  final bool bindable;

  /// The prompt shows [values] (and "required") but the parser accepts any
  /// value or none, so a near-miss is tolerated by the renderer instead of
  /// dropping the component (used where OpenUI's order is easy to get
  /// wrong, e.g. `Text("Hello")` for `Text("text", "Hello")`).
  final bool lenient;

  /// Prompt text for the type when [type] alone would be unclear.
  final String? promptType;
}

class OuiComponent {
  const OuiComponent(
    this.name,
    this.group,
    this.description,
    this.props, {
    this.hidden = false,
  });
  final String name;
  final String group;
  final String description;
  final List<OuiProp> props;

  /// Parsed and rendered, but not taught by the prompt.
  final bool hidden;

  String get signature {
    final ps = props.map((p) {
      final t = p.bindable
          ? '\$binding<${p.promptType ?? p.type}>'
          : p.values != null
          ? (_sameList(p.values!, _variants)
                ? 'Variant'
                : p.values!.map((v) => '"$v"').join('|'))
          : p.promptType ??
                switch (p.type) {
                  'text' => 'string',
                  'action' => 'Action',
                  'icon' => 'Icon',
                  'rows' => '(string|number)[][]',
                  _ => p.type,
                };
      return '${p.name}${p.required ? '' : '?'}: $t';
    });
    return '$name(${ps.join(', ')})';
  }

  /// [signature] without the trailing optional props the prompt leaves
  /// out ([_untaughtProps]); they still parse.
  String get promptSignature {
    final skip = _untaughtProps[name] ?? const <String>{};
    var n = props.length;
    while (n > 0 &&
        skip.contains(props[n - 1].name) &&
        !props[n - 1].required) {
      n--;
    }
    return OuiComponent(
      name,
      group,
      description,
      props.sublist(0, n),
    ).signature;
  }
}

bool _sameList(List<String> a, List<String> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

/// OpenUI's Tag / TextCallout variants; Tove's status components use them
/// too. The prompt calls this list `Variant`.
const _variants = ['neutral', 'info', 'success', 'warning', 'danger'];
const _calloutVariants = ['info', 'warning', 'error', 'success', 'neutral'];
const _textSizes = ['small', 'default', 'large', 'small-heavy', 'large-heavy'];
const _cardLayouts = ['grid', 'carousel'];
const _rules = OuiProp('rules', 'object', promptType: 'Rules');

/// Every component, in prompt order.
const List<OuiComponent> toveComponents = [
  // ── Root
  OuiComponent(
    'Card',
    'Root',
    'The answer container; children stack top to bottom.',
    [
      OuiProp('children', 'Node[]', required: true),
      OuiProp('sources', 'object', promptType: '{title, sourceName, url}[]'),
    ],
  ),
  // ── Content
  OuiComponent('CardHeader', 'Content', 'Title and subtitle.', [
    OuiProp('title', 'text'),
    OuiProp('subtitle', 'text'),
  ]),
  OuiComponent('InlineHeader', 'Content', 'Compact heading for a block.', [
    OuiProp('heading', 'text', required: true),
    OuiProp('description', 'text'),
  ]),
  OuiComponent('TextContent', 'Content', 'Paragraph; markdown.', [
    OuiProp('text', 'text', required: true),
    OuiProp('size', 'string', values: _textSizes),
  ]),
  OuiComponent(
    'MarkDownRenderer',
    'Content',
    'Longer markdown: lists, tables.',
    [
      OuiProp('textMarkdown', 'text', required: true),
      OuiProp('variant', 'string', values: ['clear', 'card', 'sunk']),
    ],
  ),
  OuiComponent('Callout', 'Content', 'Banner with a coloured edge.', [
    OuiProp(
      'variant',
      'string',
      required: true,
      values: _calloutVariants,
      lenient: true,
    ),
    OuiProp('title', 'text', required: true),
    OuiProp('description', 'text', required: true),
    OuiProp('visible', 'boolean', bindable: true),
  ]),
  OuiComponent('TextCallout', 'Content', 'Highlighted note.', [
    OuiProp('variant', 'string', values: _variants),
    OuiProp('title', 'text'),
    OuiProp('description', 'text'),
  ]),
  OuiComponent('Image', 'Content', 'Picture.', [
    OuiProp('alt', 'text', required: true),
    OuiProp('src', 'string'),
  ]),
  OuiComponent('ImageBlock', 'Content', 'Picture with a frame.', [
    OuiProp('src', 'string', required: true),
    OuiProp('alt', 'text'),
  ]),
  OuiComponent('ImageGallery', 'Content', 'Grid of pictures; tap to enlarge.', [
    OuiProp(
      'images',
      'object',
      required: true,
      promptType: '{src, alt?, details?}[]',
    ),
  ]),
  OuiComponent('CodeBlock', 'Content', 'Code snippet with copy.', [
    OuiProp('language', 'string', required: true),
    OuiProp('codeString', 'text', required: true),
  ]),
  OuiComponent('Separator', 'Content', '', [
    OuiProp('orientation', 'string', values: ['horizontal', 'vertical']),
    OuiProp('decorative', 'boolean'),
  ]),
  // ── Tables
  OuiComponent('Table', 'Tables', 'Column-oriented table.', [
    OuiProp('columns', 'Col[]', required: true),
  ]),
  OuiComponent('Col', 'Tables', 'A column: its label and its cells.', [
    OuiProp('label', 'text', required: true),
    OuiProp('data', 'any', required: true, promptType: '(string|number)[]'),
    OuiProp('type', 'string', values: ['string', 'number', 'action']),
  ]),
  // ── Charts
  OuiComponent('BarChart', 'Charts', 'Vertical bars by category.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('series', 'Series[]', required: true),
    OuiProp('variant', 'string', values: ['grouped', 'stacked']),
    OuiProp('xLabel', 'text'),
    OuiProp('yLabel', 'text'),
    OuiProp('height', 'number'),
  ]),
  OuiComponent('LineChart', 'Charts', 'Trends over time.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('series', 'Series[]', required: true),
    OuiProp('variant', 'string', values: ['linear', 'natural', 'step']),
    OuiProp('xLabel', 'text'),
    OuiProp('yLabel', 'text'),
    OuiProp('height', 'number'),
  ]),
  OuiComponent('AreaChart', 'Charts', 'Filled trends; totals, volume.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('series', 'Series[]', required: true),
    OuiProp('variant', 'string', values: ['linear', 'natural', 'step']),
    OuiProp('xLabel', 'text'),
    OuiProp('yLabel', 'text'),
    OuiProp('height', 'number'),
  ]),
  OuiComponent('HorizontalBarChart', 'Charts', 'Ranked lists, long labels.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('series', 'Series[]', required: true),
    OuiProp('variant', 'string', values: ['grouped', 'stacked']),
    OuiProp('xLabel', 'text'),
    OuiProp('yLabel', 'text'),
  ]),
  OuiComponent('RadarChart', 'Charts', 'Several traits per item.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('series', 'Series[]', required: true),
  ]),
  OuiComponent('Series', 'Charts', '', [
    OuiProp('category', 'text', required: true),
    OuiProp('values', 'number[]', required: true),
  ]),
  OuiComponent('PieChart', 'Charts', 'Part of a whole.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('values', 'number[]', required: true),
    OuiProp('variant', 'string', values: ['pie', 'donut']),
    OuiProp('appearance', 'string', values: ['circular', 'semiCircular']),
  ]),
  OuiComponent('RadialChart', 'Charts', 'Radial bars per segment.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('values', 'number[]', required: true),
  ]),
  OuiComponent('SingleStackedBarChart', 'Charts', 'One bar split into parts.', [
    OuiProp('labels', 'string[]', required: true),
    OuiProp('values', 'number[]', required: true),
  ]),
  OuiComponent('ScatterChart', 'Charts', 'X/Y correlation.', [
    OuiProp('datasets', 'ScatterSeries[]', required: true),
    OuiProp('xLabel', 'text'),
    OuiProp('yLabel', 'text'),
  ]),
  OuiComponent('ScatterSeries', 'Charts', '', [
    OuiProp('name', 'text', required: true),
    OuiProp('points', 'Point[]', required: true),
  ]),
  OuiComponent('Point', 'Charts', '', [
    OuiProp('x', 'number', required: true),
    OuiProp('y', 'number', required: true),
    OuiProp('z', 'number'),
  ]),
  // ── Forms
  OuiComponent(
    'Form',
    'Forms',
    'Fields plus buttons; a Button sends its label with the values.',
    [
      OuiProp('name', 'string', required: true),
      OuiProp('buttons', 'Buttons', required: true),
      OuiProp('fields', 'FormControl[]'),
    ],
  ),
  OuiComponent('FormControl', 'Forms', '', [
    OuiProp('label', 'text', required: true),
    OuiProp(
      'input',
      'Input|TextArea|Select|DatePicker|Slider|CheckBoxGroup|RadioGroup|SwitchGroup|Chips|OptionCards',
      required: true,
    ),
    OuiProp('hint', 'text'),
  ]),
  OuiComponent('Label', 'Forms', '', [OuiProp('text', 'text', required: true)]),
  OuiComponent('Input', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('placeholder', 'text'),
    OuiProp(
      'type',
      'string',
      values: ['text', 'email', 'password', 'number', 'url'],
    ),
    _rules,
    OuiProp('value', 'string', bindable: true),
  ]),
  OuiComponent('TextArea', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('placeholder', 'text'),
    OuiProp('rows', 'number'),
    _rules,
    OuiProp('value', 'string', bindable: true),
  ]),
  OuiComponent('Select', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('items', 'SelectItem[]', required: true),
    OuiProp('placeholder', 'text'),
    _rules,
    OuiProp('value', 'string', bindable: true),
  ]),
  OuiComponent('SelectItem', 'Forms', '', [
    OuiProp('value', 'text', required: true),
    OuiProp('label', 'text', required: true),
  ]),
  OuiComponent('DatePicker', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('mode', 'string', values: ['single', 'range']),
    _rules,
    OuiProp('value', 'any', bindable: true),
  ]),
  OuiComponent('Slider', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp(
      'variant',
      'string',
      required: true,
      values: ['continuous', 'discrete'],
      lenient: true,
    ),
    OuiProp('min', 'number', required: true),
    OuiProp('max', 'number', required: true),
    OuiProp('step', 'number'),
    OuiProp('defaultValue', 'number[]'),
    OuiProp('label', 'text'),
    _rules,
    OuiProp('value', 'number[]', bindable: true),
  ]),
  OuiComponent('CheckBoxGroup', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('items', 'CheckBoxItem[]', required: true),
    _rules,
    OuiProp('value', 'Record<string, boolean>', bindable: true),
  ]),
  OuiComponent('CheckBoxItem', 'Forms', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('description', 'text', required: true),
    OuiProp('name', 'string', required: true),
    OuiProp('defaultChecked', 'boolean'),
  ]),
  OuiComponent('RadioGroup', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('items', 'RadioItem[]', required: true),
    OuiProp('defaultValue', 'text'),
    _rules,
    OuiProp('value', 'string', bindable: true),
  ]),
  OuiComponent('RadioItem', 'Forms', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('description', 'text', required: true),
    OuiProp('value', 'text', required: true),
  ]),
  OuiComponent('SwitchGroup', 'Forms', '', [
    OuiProp('name', 'string', required: true),
    OuiProp('items', 'SwitchItem[]', required: true),
    OuiProp('variant', 'string', values: ['clear', 'card', 'sunk']),
    OuiProp('value', 'Record<string, boolean>', bindable: true),
  ]),
  OuiComponent('SwitchItem', 'Forms', '', [
    OuiProp('label', 'text'),
    OuiProp('description', 'text'),
    OuiProp('name', 'string', required: true),
    OuiProp('defaultChecked', 'boolean'),
  ]),
  OuiComponent('Chips', 'Forms', 'Compact pills to pick one or many.', [
    OuiProp('name', 'string', required: true),
    OuiProp('type', 'string', values: ['single', 'multiple']),
    OuiProp('items', 'ChipItem[]'),
    _rules,
    OuiProp('defaultValue', 'any', promptType: 'string|string[]'),
  ]),
  OuiComponent('ChipItem', 'Forms', '', [
    OuiProp('value', 'text', required: true),
    OuiProp('label', 'text', required: true),
    OuiProp('icon', 'icon'),
    OuiProp('disabled', 'boolean'),
  ]),
  OuiComponent('OptionCards', 'Forms', 'Selectable cards.', [
    OuiProp('name', 'string', required: true),
    OuiProp('type', 'string', values: ['single', 'multiple']),
    OuiProp('items', 'OptionCard[]'),
    _rules,
    OuiProp('defaultValue', 'any', promptType: 'string|string[]'),
  ]),
  OuiComponent('OptionCard', 'Forms', '', [
    OuiProp('value', 'text', required: true),
    OuiProp('title', 'text', required: true),
    OuiProp('subtitle', 'text'),
    OuiProp('topContent', 'Icon|Image'),
    OuiProp('disabled', 'boolean'),
  ]),
  // ── Buttons
  OuiComponent('Button', 'Buttons', 'No action = sends its label.', [
    OuiProp('label', 'text', required: true),
    OuiProp('action', 'action'),
    OuiProp('variant', 'string', values: ['primary', 'secondary', 'tertiary']),
    OuiProp('type', 'string', values: ['normal', 'destructive']),
    OuiProp(
      'size',
      'string',
      values: ['extra-small', 'small', 'medium', 'large'],
    ),
  ]),
  OuiComponent('Buttons', 'Buttons', '', [
    OuiProp('buttons', 'Button[]', required: true),
    OuiProp('direction', 'string', values: ['row', 'column']),
  ]),
  OuiComponent('Icon', 'Buttons', 'Lucide icon by kebab-case name.', [
    OuiProp('name', 'string', required: true),
    OuiProp('category', 'string'),
  ]),
  OuiComponent('IconButton', 'Buttons', '', [
    OuiProp('name', 'text', required: true),
    OuiProp('icon', 'icon', required: true),
    OuiProp('action', 'action'),
    OuiProp('variant', 'string', values: ['primary', 'secondary', 'tertiary']),
    OuiProp(
      'size',
      'string',
      values: ['extra-small', 'small', 'medium', 'large'],
    ),
    OuiProp('shape', 'string', values: ['square', 'circle']),
  ]),
  // ── Lists
  OuiComponent('ListBlock', 'Lists', 'Rows with a number or picture.', [
    OuiProp('items', 'ListItem[]', required: true),
    OuiProp('variant', 'string', values: ['number', 'image']),
    OuiProp('size', 'string', values: ['default', 'small']),
  ]),
  OuiComponent('ListItem', 'Lists', 'Tappable only with an action.', [
    OuiProp('title', 'text', required: true),
    OuiProp('subtitle', 'text'),
    OuiProp('image', 'object', promptType: '{src, alt}'),
    OuiProp('actionLabel', 'text'),
    OuiProp('action', 'action'),
  ]),
  OuiComponent(
    'FollowUpBlock',
    'Lists',
    'Follow-up suggestions, shown under the reply; last.',
    [OuiProp('items', 'FollowUpItem[]', required: true)],
  ),
  OuiComponent('FollowUpItem', 'Lists', 'Sends its text when tapped.', [
    OuiProp('text', 'text', required: true),
  ]),
  // ── Layout
  OuiComponent('SectionBlock', 'Layout', 'Foldable sections.', [
    OuiProp('sections', 'SectionItem[]', required: true),
    OuiProp('isFoldable', 'boolean'),
  ]),
  OuiComponent('SectionItem', 'Layout', '', [
    OuiProp('value', 'string', required: true),
    OuiProp('trigger', 'text', required: true),
    OuiProp('content', 'Node[]', required: true),
  ]),
  OuiComponent('Tabs', 'Layout', 'One pane at a time.', [
    OuiProp('items', 'TabItem[]', required: true),
  ]),
  OuiComponent('TabItem', 'Layout', '', [
    OuiProp('value', 'string', required: true),
    OuiProp('trigger', 'text', required: true),
    OuiProp('content', 'Node[]', required: true),
  ]),
  OuiComponent('Accordion', 'Layout', 'Collapsed sections.', [
    OuiProp('items', 'AccordionItem[]', required: true),
  ]),
  OuiComponent('AccordionItem', 'Layout', '', [
    OuiProp('value', 'string', required: true),
    OuiProp('trigger', 'text', required: true),
    OuiProp('content', 'Node[]', required: true),
  ]),
  OuiComponent('Steps', 'Layout', 'Numbered timeline.', [
    OuiProp('items', 'StepsItem[]', required: true),
  ]),
  OuiComponent('StepsItem', 'Layout', '', [
    OuiProp('title', 'text', required: true),
    OuiProp('details', 'text', required: true),
  ]),
  OuiComponent(
    'Carousel',
    'Layout',
    'Horizontal slides; each slide is a list of components, all slides alike.',
    [
      OuiProp('children', 'Node[][]', required: true),
      OuiProp('variant', 'string', values: ['card', 'sunk']),
    ],
  ),
  // ── Data display
  OuiComponent('TagBlock', 'Data', '', [
    OuiProp('tags', 'string[]', required: true),
    OuiProp('size', 'string', values: ['sm', 'md', 'lg']),
  ]),
  OuiComponent('Tag', 'Data', 'Badge.', [
    OuiProp('text', 'text', required: true),
    OuiProp('icon', 'icon'),
    OuiProp('size', 'string', values: ['sm', 'md', 'lg']),
    OuiProp('variant', 'string', values: _variants),
  ]),
  OuiComponent(
    'EntityList',
    'Data',
    'Label/value rows; specs, facts, totals.',
    [
      OuiProp(
        'rows',
        'object',
        promptType: '{left, right, rightVariant?: "text"|"number"}[]',
      ),
      OuiProp('size', 'string', values: ['small', 'default']),
      OuiProp('header', 'object', promptType: '{left, right}'),
      OuiProp('footer', 'object', promptType: '{left, right}'),
    ],
  ),
  // ── Card blocks (2+ items, every item the same shape)
  OuiComponent(
    'SnippetCardBlock',
    'Cards',
    'Small label/value cards, 2 per row.',
    [
      OuiProp('items', 'SnippetCardItem[]', required: true),
      OuiProp('layout', 'string', values: ['grid']),
      OuiProp('responsive', 'boolean'),
      OuiProp('action', 'action'),
      OuiProp('gap', 'any'),
    ],
  ),
  OuiComponent('SnippetCardItem', 'Cards', '', [
    OuiProp('id', 'string'),
    OuiProp('lhs', 'IconText|ImageText', required: true),
    OuiProp('rhs', 'Text|BoldText'),
  ]),
  OuiComponent('OverviewCardBlock', 'Cards', 'KPI cards.', [
    OuiProp('items', 'OverviewCardItem[]', required: true),
    OuiProp('layout', 'string', values: _cardLayouts),
    OuiProp('responsive', 'boolean'),
    OuiProp('action', 'action'),
    OuiProp('gap', 'any'),
  ]),
  OuiComponent('OverviewCardItem', 'Cards', '', [
    OuiProp('id', 'string'),
    OuiProp('top', 'IconText|ImageText|Text', required: true),
    OuiProp('bottom', 'MetricIndicatorInline'),
  ]),
  OuiComponent('ContextCardBlock', 'Cards', 'Summary cards.', [
    OuiProp('items', 'ContextCardItem[]', required: true),
    OuiProp('layout', 'string', values: _cardLayouts),
    OuiProp('responsive', 'boolean'),
    OuiProp('action', 'action'),
    OuiProp('gap', 'any'),
  ]),
  OuiComponent('ContextCardItem', 'Cards', '', [
    OuiProp('id', 'string'),
    OuiProp('title', 'any', required: true, promptType: 'string|Tag'),
    OuiProp('body', 'text'),
    OuiProp('bgColor', 'string', values: ['gray']),
    OuiProp('bgImageSrc', 'string'),
    OuiProp('bgImageAlt', 'text'),
  ]),
  OuiComponent(
    'CompositeCardBlock',
    'Cards',
    'Rich cards; products, offers, places.',
    [
      OuiProp('items', 'CompositeCardItem[]', required: true),
      OuiProp('layout', 'string', values: _cardLayouts),
      OuiProp('responsive', 'boolean'),
      OuiProp('action', 'action'),
      OuiProp('gap', 'any'),
    ],
  ),
  OuiComponent(
    'CompositeCardItem',
    'Cards',
    'body: Text, BoldText, MetricIndicatorInline, IconText, Image, charts, ListBlock, TagBlock, EntityList.',
    [
      OuiProp('id', 'string'),
      OuiProp('header', 'IconText|ImageText|ImageTextLarge|Text|Image'),
      OuiProp('body', 'Node[]'),
      OuiProp(
        'footer',
        'object',
        promptType: '{price?: BoldText|MetricIndicatorWithStrikethrough, button?: Button}',
      ),
    ],
  ),
  OuiComponent('VisualCardBlock', 'Cards', 'Photo-first cards.', [
    OuiProp('items', 'VisualCardItem[]', required: true),
    OuiProp('layout', 'string', values: _cardLayouts),
    OuiProp('responsive', 'boolean'),
    OuiProp('action', 'action'),
    OuiProp('gap', 'any'),
  ]),
  OuiComponent('VisualCardItem', 'Cards', '', [
    OuiProp('body', 'BoldText', required: true),
    OuiProp('id', 'string'),
    OuiProp('bgImageSrc', 'string'),
    OuiProp('tag', 'Tag'),
    OuiProp('bgImageAlt', 'text'),
  ]),
  OuiComponent('Text', 'Cards', 'Inside card items only.', [
    OuiProp('variant', 'string', values: ['text', 'number'], lenient: true),
    OuiProp('value', 'text', required: true, lenient: true),
    OuiProp('subtext', 'text'),
    OuiProp('subtextVariant', 'string', values: ['text', 'number', 'metric']),
    OuiProp('size', 'string', values: ['xs', 'sm', 'md', 'lg']),
  ]),
  OuiComponent('BoldText', 'Cards', '', [
    OuiProp('variant', 'string', values: ['text', 'number'], lenient: true),
    OuiProp('value', 'text', required: true, lenient: true),
    OuiProp('subtext', 'text'),
    OuiProp('subtextVariant', 'string', values: ['text', 'number', 'metric']),
    OuiProp('size', 'string', values: ['xs', 'sm', 'md', 'lg']),
  ]),
  OuiComponent('IconText', 'Cards', '', [
    OuiProp('icon', 'icon', required: true),
    OuiProp(
      'iconVariant',
      'string',
      values: [..._variants, 'inverted', 'filled', 'soft'],
    ),
    OuiProp('iconSize', 'string', values: ['xs', 's', 'm', 'l', 'xl']),
    OuiProp('title', 'text', required: true),
    OuiProp('subtitle', 'text'),
    OuiProp('bold', 'boolean'),
    OuiProp('layout', 'string', values: ['horizontal', 'vertical']),
  ]),
  OuiComponent('ImageText', 'Cards', 'Thumbnail with a title.', [
    OuiProp('src', 'string', required: true),
    OuiProp('alt', 'text'),
    OuiProp('title', 'text', required: true),
    OuiProp('subtitle', 'text'),
    OuiProp('bold', 'boolean'),
    OuiProp('layout', 'string', values: ['horizontal', 'vertical']),
    OuiProp('imageSize', 'number'),
  ]),
  OuiComponent('ImageTextLarge', 'Cards', 'Banner picture with a title.', [
    OuiProp('src', 'string', required: true),
    OuiProp('alt', 'text'),
    OuiProp('title', 'text', required: true),
    OuiProp('subtitle', 'text'),
    OuiProp('bold', 'boolean'),
  ]),
  OuiComponent('MetricIndicatorInline', 'Cards', '', [
    OuiProp('value', 'text', required: true),
    OuiProp('subtext', 'text'),
    OuiProp(
      'trend',
      'object',
      promptType: '{direction: "up"|"down", value: number}',
    ),
  ]),
  OuiComponent('MetricIndicatorWithStrikethrough', 'Cards', '', [
    OuiProp('value', 'text', required: true),
    OuiProp('subtext', 'text'),
    OuiProp('previousValue', 'text'),
    OuiProp(
      'trend',
      'object',
      promptType: '{direction: "up"|"down", value: number}',
    ),
  ]),
  // ── Tove custom components
  OuiComponent(
    'Email',
    'Tove',
    'Every email, message or letter the user will send, however short. body '
        'only, signed with the user\'s name when known; to = names or '
        'addresses, [] if unknown. Shows Copy and Send (Gmail, mail app).',
    [
      OuiProp('to', 'string[]', required: true),
      OuiProp('subject', 'text', required: true),
      OuiProp('body', 'text', required: true),
      OuiProp('cc', 'string[]'),
    ],
  ),
  OuiComponent(
    'Artifact',
    'Tove',
    'A whole program, script, config file or long draft (about 15 lines or '
        'more) the user will copy or save; opens full screen.',
    [
      OuiProp('title', 'text', required: true),
      OuiProp('content', 'text', required: true),
      OuiProp(
        'kind',
        'string',
        values: ['code', 'script', 'config', 'draft', 'document'],
      ),
      OuiProp('language', 'string'),
      OuiProp('file', 'string'),
    ],
  ),
  OuiComponent(
    'Checklist',
    'Tove',
    'Plans, routines, to-do lists; ticks are saved. At most 40 items.',
    [
      OuiProp('sections', 'ChecklistSection[]', required: true),
      OuiProp('title', 'text'),
    ],
  ),
  OuiComponent(
    'ChecklistSection',
    'Tove',
    'icon: focus|work|rest|morning|home|health|food|learn|code|travel|money|social|errands|homelab|calendar.',
    [
      OuiProp('title', 'text', required: true),
      OuiProp('items', 'string[]', required: true),
      OuiProp('time', 'text'),
      OuiProp('icon', 'string'),
    ],
  ),
  OuiComponent(
    'Entities',
    'Tove',
    'Picture cards for the people, places, organisations or products the '
        'answer is about; a tap opens their details.',
    [OuiProp('items', 'Entity[]', required: true)],
  ),
  OuiComponent('Entity', 'Tove', 'image: "entity:Wikipedia_Title".', [
    OuiProp('name', 'text', required: true),
    OuiProp('subtitle', 'text'),
    OuiProp('image', 'string'),
    OuiProp('about', 'text'),
  ]),
  OuiComponent('News', 'Tove', 'Article rows with publisher and date.', [
    OuiProp('items', 'Article[]', required: true),
  ]),
  OuiComponent('Article', 'Tove', '', [
    OuiProp('title', 'text', required: true),
    OuiProp('url', 'string', required: true),
    OuiProp('source', 'text'),
    OuiProp('date', 'text'),
    OuiProp('image', 'string'),
  ]),
  OuiComponent('Status', 'Tove', 'Overall health headline.', [
    OuiProp('title', 'text', required: true),
    OuiProp('variant', 'string', values: _variants),
    OuiProp('summary', 'text'),
    OuiProp('updated', 'text'),
  ]),
  OuiComponent(
    'Services',
    'Tove',
    'One row per machine or service; a tap sends ask.',
    [OuiProp('items', 'Service[]', required: true), OuiProp('title', 'text')],
  ),
  OuiComponent('Service', 'Tove', '', [
    OuiProp('name', 'text', required: true),
    OuiProp('variant', 'string', values: _variants),
    OuiProp('latency', 'text'),
    OuiProp('subtitle', 'text'),
    OuiProp('ask', 'text'),
  ]),
  OuiComponent('Gauges', 'Tove', 'Usage rings: CPU, memory, disk, battery.', [
    OuiProp('items', 'Gauge[]', required: true),
  ]),
  OuiComponent('Gauge', 'Tove', '', [
    OuiProp('label', 'text', required: true),
    OuiProp('value', 'number', required: true),
    OuiProp('max', 'number'),
    OuiProp('unit', 'string'),
    OuiProp('variant', 'string', values: _variants),
  ]),
  // ── Parsed for tolerance, not taught: OpenUI's base-library Stack.
  OuiComponent('Stack', 'Layout', '', [
    OuiProp('children', 'Node[]', required: true),
    OuiProp('direction', 'string'),
    OuiProp('gap', 'string'),
    OuiProp('align', 'string'),
    OuiProp('justify', 'string'),
    OuiProp('wrap', 'boolean'),
  ], hidden: true),
];

/// Components that render but the prompt leaves out to save tokens: the
/// rarer OpenUI chat-library pieces. A model that writes them still gets
/// them drawn.
const Set<String> _untaught = {
  'TextCallout',
  'Separator',
  'RadarChart',
  'RadialChart',
  'ScatterChart',
  'ScatterSeries',
  'Point',
  'Label',
  'CheckBoxGroup',
  'CheckBoxItem',
  'SwitchGroup',
  'SwitchItem',
  'IconButton',
  'SnippetCardBlock',
  'SnippetCardItem',
  'ContextCardBlock',
  'ContextCardItem',
  'MetricIndicatorWithStrikethrough',
};

/// Trailing optional props the prompt leaves out (they still parse).
const Map<String, Set<String>> _untaughtProps = {
  'Card': {'sources'},
  'Callout': {'visible'},
  'BarChart': {'xLabel', 'yLabel', 'height'},
  'LineChart': {'xLabel', 'yLabel', 'height'},
  'AreaChart': {'xLabel', 'yLabel', 'height'},
  'HorizontalBarChart': {'xLabel', 'yLabel'},
  'Button': {'size'},
  'Select': {'value', 'rules', 'placeholder'},
  'Chips': {'defaultValue', 'rules'},
  'OptionCards': {'defaultValue', 'rules'},
  'ChipItem': {'icon', 'disabled'},
  'OptionCard': {'disabled', 'topContent'},
  'Icon': {'category'},
  'OverviewCardBlock': {'gap'},
  'CompositeCardBlock': {'gap'},
  'VisualCardBlock': {'gap'},
  'IconText': {'layout', 'bold'},
  'ImageText': {'imageSize', 'layout', 'bold'},
  'ImageTextLarge': {'bold'},
  'Text': {'size'},
  'BoldText': {'size'},
  'Carousel': {'variant'},
  'TagBlock': {'size'},
};

/// Whether the prompt teaches [c] (others still parse and render).
bool isTaught(OuiComponent c) => !c.hidden && !_untaught.contains(c.name);

/// Short notes printed under a group in the prompt.
const Map<String, List<String>> _groupNotes = {
  'Forms': [
    'Define each FormControl as its own statement. Never nest a Form. '
        'Rules = {required: true, min: 1, maxLength: 80, email: true, …}.',
  ],
  'Cards': [
    'Text, BoldText, IconText, ImageText, ImageTextLarge and MetricIndicator* '
        'go inside card items only.',
  ],
};

Map<String, Object?> _schemaFor(OuiProp p, Set<String> names) {
  if (p.bindable) return {};
  if (p.values != null) {
    return p.lenient ? {} : {'type': 'string', 'enum': p.values};
  }
  final t = p.type;
  if (t == 'text') {
    return {
      'anyOf': [
        {'type': 'string'},
        {'type': 'number'},
      ],
    };
  }
  if (t == 'string' || t == 'number' || t == 'boolean') return {'type': t};
  if (t == 'string[]') {
    return {
      'type': 'array',
      'items': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'number'},
        ],
      },
    };
  }
  if (t == 'number[]' || t == 'Node[][]') return {'type': 'array'};
  if (t == 'rows') {
    return {
      'type': 'array',
      'items': {'type': 'array'},
    };
  }
  if (t == 'action') return {r'$ref': r'#/$defs/ActionExpression'};
  if (t == 'Node[]') {
    return {
      'type': 'array',
      'items': {
        'anyOf': [
          for (final n in names) {r'$ref': '#/\$defs/$n'},
        ],
      },
    };
  }
  if (t.endsWith('[]') && names.contains(t.substring(0, t.length - 2))) {
    return {
      'type': 'array',
      'items': {r'$ref': '#/\$defs/${t.substring(0, t.length - 2)}'},
    };
  }
  final parts = t.split('|');
  if (parts.every(names.contains)) {
    return parts.length == 1
        ? {r'$ref': '#/\$defs/${parts.single}'}
        : {
            'anyOf': [
              for (final n in parts) {r'$ref': '#/\$defs/$n'},
            ],
          };
  }
  return {}; // icon, object, any: checked by the renderer
}

/// The LibrarySpec JSON Schema (the `library.toJSONSchema()` shape) of
/// [components].
Map<String, Object?> librarySchema(List<OuiComponent> components) {
  final names = {for (final c in components) c.name};
  return {
    'properties': {
      for (final c in components) c.name: {r'$ref': '#/\$defs/${c.name}'},
    },
    r'$defs': {
      for (final c in components)
        c.name: {
          'type': 'object',
          'description': c.description,
          'properties': {for (final p in c.props) p.name: _schemaFor(p, names)},
          'required': [
            for (final p in c.props)
              if (p.required && !p.lenient) p.name,
          ],
        },
      'ActionExpression': {
        'anyOf': [
          {'type': 'object'},
        ],
      },
    },
    'actions': {
      'Copy': {
        'description': 'Copy text to the clipboard',
        'params': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
          'required': ['text'],
        },
      },
    },
  };
}

Map<String, Object?> toveLibrarySchema() => librarySchema(toveComponents);

CompiledLibrary? _compiled, _legacy;

/// The compiled Tove library (OpenUI chat library names, root `Card`).
CompiledLibrary get toveLibrary =>
    _compiled ??= compileSchema(toveLibrarySchema(), root: 'Card');

/// The round-9 Tove library (root `Stack`), for replies written with it.
CompiledLibrary get legacyLibrary =>
    _legacy ??= compileSchema(librarySchema(legacyComponents), root: 'Stack');

/// Names only the round-9 set has, plus its root `Stack` (the current set
/// parses Stack only for tolerance).
final Set<String> _legacyOnly = {for (final c in legacyComponents) c.name}
    .difference({
      for (final c in toveComponents)
        if (!c.hidden) c.name,
    });

/// Names only the current set has.
final Set<String> _currentOnly = {
  for (final c in toveComponents)
    if (!c.hidden) c.name,
}.difference({for (final c in legacyComponents) c.name});

final _call = RegExp(r'(?<![\w$@.])([A-Z]\w*)\s*\(');
final _rootCall = RegExp(r'^\s*root\s*=\s*([A-Z]\w*)\s*\(', multiLine: true);
final Set<String> _legacyNames = {for (final c in legacyComponents) c.name};

/// Whether [source] was written for the round-9 set: its root is a round-9
/// component other than Card, or it calls more of that set's own names
/// than of the current set's. Decided on whatever has
/// streamed so far; a program with neither counts as current.
bool isLegacyProgram(String source) {
  var legacy = 0, current = 0;
  // The current set's root is always Card; a round-9 reply may start with
  // any of its own components (root = Table([...]) or Stack([...])).
  final root = _rootCall.firstMatch(source)?[1];
  if (root != null && root != 'Card' && _legacyNames.contains(root)) legacy++;
  for (final m in _call.allMatches(source)) {
    final n = m[1]!;
    if (_legacyOnly.contains(n)) legacy++;
    if (_currentOnly.contains(n)) current++;
  }
  return legacy > current;
}

/// Custom action specs for the evaluator.
Map<String, Map<String, Object?>> get toveActions => {
  for (final e in (toveLibrarySchema()['actions']! as Map).entries)
    '${e.key}': (e.value as Map).cast<String, Object?>(),
};

class _Bindings implements SchemaContext {
  _Bindings(List<OuiComponent> components)
    : _bindable = {
        for (final c in components)
          c.name: {
            for (final p in c.props)
              if (p.bindable) p.name,
          },
      };
  final Map<String, Set<String>> _bindable;
  @override
  bool isReactive(String component, String prop) =>
      _bindable[component]?.contains(prop) ?? false;
}

final SchemaContext toveBindings = _Bindings(toveComponents);
final SchemaContext legacyBindings = _Bindings(legacyComponents);

const _groupTitles = {
  'Root': 'Root',
  'Content': 'Content',
  'Tables': 'Tables',
  'Charts': 'Charts',
  'Forms': 'Forms (state is local until a Button sends it)',
  'Buttons': 'Buttons',
  'Lists': 'Lists and follow-ups',
  'Layout': 'Layout',
  'Data': 'Data display',
  'Cards': 'Card blocks (2+ items, every item the same shape)',
  'Tove': 'Tove components',
};

/// The OpenUI section of the bridge's system prompt (clients that send
/// `"ui": 2`), generated from [toveComponents]. `server/openui-prompt.md`
/// must equal this (a test checks it).
String toveOpenUiPrompt() {
  final b = StringBuffer()
    ..writeln('## Rich answers: OpenUI')
    ..writeln()
    ..writeln(
      'This app draws OpenUI Lang (openui.com, its chat component library) '
      'natively. Plain markdown is the default. When an answer needs layout '
      'or interaction, write ONE ```openui fence; a sentence of markdown may '
      'come before it. Use it for: comparing products, places or options; '
      'trip plans and itineraries (Tabs per day, Steps inside); recipes '
      '(EntityList for time and servings, ingredients, Steps for the '
      'method); server, homelab or service status (Status, Services, '
      'Gauges, Callout per problem); lists of people, places or products '
      'with pictures; plans, routines and to-do lists (Checklist); every '
      'email, message or letter the user will send (Email); whole programs, '
      'configs and long drafts (Artifact); choices the user taps. Facts, '
      'explanations, chat, short lists and code snippets stay markdown. '
      'Never wrap a plain paragraph in openui and never repeat its content '
      'in prose.',
    )
    ..writeln()
    ..writeln('Syntax:')
    ..writeln(
      '- One statement per line: `name = Expr`. The first line is '
      '`root = Card([...])`; then define children top-down, so the answer '
      'renders while it streams.',
    )
    ..writeln(
      '- Arguments are positional, in the order shown; never `name:` labels. '
      'Omit optional trailing args; `null` skips one.',
    )
    ..writeln(
      '- Strings in double quotes, `[a, b]` lists, `{k: v}` objects. Every '
      'defined name must be used by its parent.',
    )
    ..writeln(
      '- State: `\$n = 2` declares; `\$binding` props edit it; expressions '
      'like `"Total: " + \$n * 3`, `c ? a : b`, `@Round(x, 1)`, `@Sum(list)`.',
    )
    ..writeln(
      '- Actions: `@ToAssistant("text")` sends text as the user\'s next '
      'message, in their voice; `@OpenUrl("https://…")` opens after a '
      'confirm; `@Set(\$x, v)`; several: `Action([a, b])`. A Button without '
      'an action sends its label; inside a Form it also sends the values. '
      'Nothing else runs.',
    )
    ..writeln(
      '- Pictures: for named things (people, places, products, foods, '
      'artworks) the image URL is `"entity:English_Wikipedia_Title"`; other '
      'pictures only from image_search results, copied exactly. Never invent '
      'URLs.',
    )
    ..writeln(
      '- Citations ([^1] footnotes) go in the markdown around the fence, '
      'not inside it.',
    )
    ..writeln()
    ..writeln(
      'Components (Node = any component; ? = optional; Variant = '
      '${_variants.map((v) => '"$v"').join('|')}):',
    );
  String? group;
  for (final c in toveComponents) {
    if (c.hidden || _untaught.contains(c.name)) continue;
    if (c.group != group) {
      if (group != null) {
        for (final n in _groupNotes[group] ?? const <String>[]) {
          b.writeln('- $n');
        }
      }
      group = c.group;
      b.writeln('### ${_groupTitles[group] ?? group}');
    }
    b.writeln(
      c.description.isEmpty
          ? c.promptSignature
          : '${c.promptSignature} – ${c.description}',
    );
  }
  for (final n in _groupNotes[group] ?? const <String>[]) {
    b.writeln('- $n');
  }
  b
    ..writeln()
    ..writeln('Example:')
    ..writeln('```openui')
    ..writeln('root = Card([head, picks, specs, verdict, more])')
    ..writeln(
      'head = CardHeader("Pixel 10 vs iPhone 17", "Two flagship phones")',
    )
    ..writeln('picks = CompositeCardBlock([a, b])')
    ..writeln(
      'a = CompositeCardItem(null, ImageTextLarge("entity:Pixel_10", "Pixel 10", '
      '"Pixel 10", "Best camera AI"), [TagBlock(["7 years updates"])], '
      '{price: BoldText("text", "\$799")})',
    )
    ..writeln(
      'b = CompositeCardItem(null, ImageTextLarge("entity:IPhone_17", "iPhone 17", '
      '"iPhone 17", "Fastest chip"), [TagBlock(["120 Hz"])], '
      '{price: BoldText("text", "\$829")})',
    )
    ..writeln(
      'specs = Table([Col("Spec", ["Battery", "Weight"]), Col("Pixel 10", '
      '["4,970 mAh", "204 g"]), Col("iPhone 17", ["3,900 mAh", "177 g"])])',
    )
    ..writeln(
      'verdict = Callout("success", "Verdict", "Pixel for photos and battery, '
      'iPhone for speed.")',
    )
    ..writeln(
      'more = FollowUpBlock([FollowUpItem("Which has the better camera?")])',
    )
    ..writeln('```');
  return b.toString();
}
