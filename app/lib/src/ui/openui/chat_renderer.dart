part of 'openui_block.dart';

// The OpenUI chat library drawn with Tove's widgets. Layout follows
// OpenUI's default react-ui components (spacing 4/6/8/12/18/24, 24 px step
// circles on a connector, coloured-edge callouts, two-per-row card blocks,
// hairline-divided rows); colour follows Tove's blend rule: no fills, 1 px
// outlines group, colour only for state.

const _lucide = <String, IconData>{
  'check': Icons.check_rounded,
  'circle-check': Icons.check_circle_outline_rounded,
  'check-circle': Icons.check_circle_outline_rounded,
  'x': Icons.close_rounded,
  'circle-x': Icons.cancel_outlined,
  'alert-triangle': Icons.warning_amber_rounded,
  'triangle-alert': Icons.warning_amber_rounded,
  'alert-circle': Icons.error_outline_rounded,
  'circle-alert': Icons.error_outline_rounded,
  'info': Icons.info_outline_rounded,
  'star': Icons.star_outline_rounded,
  'heart': Icons.favorite_border_rounded,
  'clock': Icons.schedule_rounded,
  'calendar': Icons.event_outlined,
  'map-pin': Icons.place_outlined,
  'map': Icons.map_outlined,
  'plane': Icons.flight_rounded,
  'train': Icons.train_outlined,
  'car': Icons.directions_car_outlined,
  'bus': Icons.directions_bus_outlined,
  'hotel': Icons.hotel_outlined,
  'bed': Icons.bed_outlined,
  'utensils': Icons.restaurant_outlined,
  'coffee': Icons.coffee_outlined,
  'shopping-cart': Icons.shopping_cart_outlined,
  'shopping-bag': Icons.shopping_bag_outlined,
  'dollar-sign': Icons.attach_money_rounded,
  'indian-rupee': Icons.currency_rupee_rounded,
  'wallet': Icons.account_balance_wallet_outlined,
  'credit-card': Icons.credit_card_rounded,
  'trending-up': Icons.trending_up_rounded,
  'trending-down': Icons.trending_down_rounded,
  'chart-line': Icons.show_chart_rounded,
  'bar-chart': Icons.bar_chart_rounded,
  'chart-bar': Icons.bar_chart_rounded,
  'activity': Icons.monitor_heart_outlined,
  'cpu': Icons.memory_rounded,
  'server': Icons.dns_outlined,
  'database': Icons.storage_rounded,
  'hard-drive': Icons.storage_rounded,
  'wifi': Icons.wifi_rounded,
  'battery': Icons.battery_full_rounded,
  'zap': Icons.bolt_rounded,
  'shield': Icons.shield_outlined,
  'lock': Icons.lock_outline_rounded,
  'user': Icons.person_outline_rounded,
  'users': Icons.group_outlined,
  'mail': Icons.mail_outline_rounded,
  'phone': Icons.call_outlined,
  'message-circle': Icons.chat_bubble_outline_rounded,
  'globe': Icons.language_rounded,
  'link': Icons.link_rounded,
  'external-link': Icons.open_in_new_rounded,
  'search': Icons.search_rounded,
  'settings': Icons.settings_outlined,
  'home': Icons.home_outlined,
  'book': Icons.menu_book_outlined,
  'book-open': Icons.menu_book_outlined,
  'graduation-cap': Icons.school_outlined,
  'briefcase': Icons.work_outline_rounded,
  'code': Icons.code_rounded,
  'terminal': Icons.terminal_rounded,
  'file': Icons.description_outlined,
  'file-text': Icons.description_outlined,
  'image': Icons.image_outlined,
  'camera': Icons.photo_camera_outlined,
  'music': Icons.music_note_outlined,
  'film': Icons.movie_outlined,
  'gamepad': Icons.sports_esports_outlined,
  'dumbbell': Icons.fitness_center_rounded,
  'sun': Icons.wb_sunny_outlined,
  'moon': Icons.bedtime_outlined,
  'cloud': Icons.cloud_outlined,
  'cloud-rain': Icons.water_drop_outlined,
  'thermometer': Icons.thermostat_rounded,
  'leaf': Icons.eco_outlined,
  'flame': Icons.local_fire_department_outlined,
  'gift': Icons.card_giftcard_rounded,
  'tag': Icons.sell_outlined,
  'package': Icons.inventory_2_outlined,
  'truck': Icons.local_shipping_outlined,
  'bell': Icons.notifications_none_rounded,
  'lightbulb': Icons.lightbulb_outline_rounded,
  'target': Icons.track_changes_rounded,
  'flag': Icons.flag_outlined,
  'award': Icons.emoji_events_outlined,
  'trophy': Icons.emoji_events_outlined,
  'thumbs-up': Icons.thumb_up_outlined,
  'thumbs-down': Icons.thumb_down_outlined,
  'plus': Icons.add_rounded,
  'minus': Icons.remove_rounded,
  'arrow-right': Icons.arrow_forward_rounded,
  'arrow-up': Icons.arrow_upward_rounded,
  'arrow-down': Icons.arrow_downward_rounded,
  'chevron-right': Icons.chevron_right_rounded,
  'refresh-cw': Icons.refresh_rounded,
  'rotate-cw': Icons.refresh_rounded,
  'play': Icons.play_arrow_rounded,
  'pause': Icons.pause_rounded,
  'download': Icons.download_rounded,
  'upload': Icons.upload_rounded,
  'share': Icons.share_outlined,
  'copy': Icons.content_copy_rounded,
  'trash': Icons.delete_outline_rounded,
  'edit': Icons.edit_outlined,
  'pencil': Icons.edit_outlined,
  'sparkles': Icons.auto_awesome_outlined,
  'smartphone': Icons.smartphone_rounded,
  'laptop': Icons.laptop_rounded,
  'monitor': Icons.monitor_rounded,
  'headphones': Icons.headphones_rounded,
  'baby': Icons.child_friendly_outlined,
  'dog': Icons.pets_rounded,
  'pill': Icons.medication_outlined,
  'stethoscope': Icons.medical_services_outlined,
  'building': Icons.apartment_rounded,
  'mountain': Icons.terrain_rounded,
  'tree': Icons.park_outlined,
  'waves': Icons.waves_rounded,
  'ticket': Icons.confirmation_number_outlined,
  'list': Icons.list_rounded,
  'list-checks': Icons.checklist_rounded,
};

IconData ouiIcon(String? name) {
  final n = (name ?? '').trim().toLowerCase().replaceAll('_', '-');
  return _lucide[n] ??
      _lucide[n.replaceAll(RegExp(r'-\d+$'), '')] ??
      Icons.circle_outlined;
}

UiTone _variantTone(Object? v) => switch (_str(v)) {
  'success' || 'good' || 'ok' || 'up' => UiTone.good,
  'warning' || 'warn' || 'degraded' => UiTone.warn,
  'danger' || 'error' || 'bad' || 'down' || 'destructive' => UiTone.bad,
  'info' => UiTone.info,
  _ => UiTone.neutral,
};

class _ChatRenderer extends _RendererBase {
  _ChatRenderer(super.state, super.h, super.s, this.accent);
  final Color accent;

  /// The Form being built ("" outside a form).
  String _form = '';

  /// Fields of the Form being built, for its buttons.
  List<_FieldMeta>? _fields;

  Color _toneColor(UiTone t) => switch (t) {
    UiTone.good => s.success,
    UiTone.warn || UiTone.tip => s.warning,
    UiTone.bad => s.danger,
    UiTone.info => accent,
    UiTone.neutral => s.textMuted,
  };

  BoxDecoration _frame({Color? border, double? radius}) => BoxDecoration(
    border: Border.all(color: border ?? s.outline),
    borderRadius: BorderRadius.circular(radius ?? s.frameRadius + 4),
  );

  /// Text/BoldText value with OpenUI's variant-first order tolerated.
  String? _value(Map<String, Object?> p) {
    final v = _str(p['value']);
    if (v != null) return v;
    final variant = _str(p['variant']);
    return variant == 'text' || variant == 'number' ? null : variant;
  }

  bool _picture(Object? v) => _isPicture(_str(v));

  Widget _image(
    String url, {
    double? height,
    double radius = 14,
    double aspect = 0.56,
  }) => LayoutBuilder(
    builder: (context, c) => UiRemoteImageBox(
      url: url,
      width: c.maxWidth,
      height: height ?? (c.maxWidth * aspect).clamp(120.0, 260.0),
      style: s,
      radius: radius,
    ),
  );

  @override
  Widget build(ElementNode e) {
    final p = e.props;
    switch (e.typeName) {
      case unknownTextType:
        return Text(_str(p['text']) ?? '', style: s.body);
      case 'Card':
        return _rootCard(e);
      case 'Stack':
        final kids = [for (final c in _els(p['children'])) node(c)];
        return _str(p['direction']) == 'row'
            ? _grid(kids, kids.length.clamp(1, 3))
            : column(kids);
      // ── Content
      case 'CardHeader':
        final t = _str(p['title']), st = _str(p['subtitle']);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (t != null) Semantics(header: true, child: Text(t, style: s.h3)),
            if (st != null) ...[
              const SizedBox(height: 4),
              Text(st, style: s.body.copyWith(color: s.textMuted)),
            ],
          ],
        );
      case 'InlineHeader':
        final d = _str(p['description']);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(_str(p['heading']) ?? '', style: s.bodyStrong),
            ),
            if (d != null) Text(d, style: s.caption),
          ],
        );
      case 'TextContent':
        return _textContent(_str(p['text']) ?? '', _str(p['size']));
      case 'MarkDownRenderer':
        final md = _markdown(_citations(_str(p['textMarkdown']) ?? ''));
        final v = _str(p['variant']);
        if (v == 'card' || v == 'sunk') {
          return Container(
            decoration: _frame(),
            padding: const EdgeInsets.all(14),
            child: md,
          );
        }
        return md;
      case 'Callout':
        if (p['visible'] == false) return const SizedBox.shrink();
        return _edgeCallout(
          _variantTone(p['variant']),
          _str(p['title']),
          _str(p['description']),
        );
      case 'TextCallout':
        return UiElementView(
          style: s,
          element: UiCallout(
            tone: _variantTone(p['variant']),
            title: _str(p['title']),
            body: _str(p['description']) ?? '',
          ),
        );
      case 'Image' || 'ImageBlock':
        final src = _str(p['src']);
        if (!_isPicture(src)) return const SizedBox.shrink();
        if (_entityRef(src) != null) return _image(src!, aspect: 0.6);
        final alt = (_str(p['alt']) ?? '').replaceAll(RegExp(r'[\[\]]'), '');
        return _markdown('![$alt](<$src>)');
      case 'ImageGallery':
        final imgs = [
          for (final x
              in (p['images'] is List ? p['images']! as List : const []))
            if (x is Map && _picture(x['src']))
              (_str(x['src'])!, _str(x['alt']) ?? '')
            else if (x is String && _isPicture(x))
              (x, ''),
        ].take(8).toList();
        if (imgs.isEmpty) return const SizedBox.shrink();
        if (imgs.any((i) => _entityRef(i.$1) != null)) {
          return DrawerSwipeExclusion(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (i, img) in imgs.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    UiRemoteImageBox(
                      url: img.$1,
                      width: 200,
                      height: 150,
                      style: s,
                      radius: 14,
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return _markdown(
          imgs
              .map(
                (i) =>
                    '![${i.$2.replaceAll(RegExp(r'[\[\]]'), '')}](<${i.$1}>)',
              )
              .join(' '),
        );
      case 'CodeBlock':
        return CodeBlock(
          code: _str(p['codeString']) ?? '',
          language: _str(p['language']),
          style: s,
        );
      case 'Separator':
        return Divider(height: 1, thickness: 1, color: s.hairline);
      // ── Tables
      case 'Table':
        return _table(_els(p['columns'], 'Col'));
      // ── Charts
      case 'BarChart' ||
          'LineChart' ||
          'AreaChart' ||
          'HorizontalBarChart' ||
          'RadarChart' ||
          'PieChart' ||
          'RadialChart' ||
          'SingleStackedBarChart' ||
          'ScatterChart':
        return OuiChartView(data: ouiChartData(e), style: s);
      // ── Forms
      case 'Form':
        return _formView(e);
      case 'FormControl':
        return _formControl(e);
      case 'Label':
        return Text(
          _str(p['text']) ?? '',
          style: s.body.copyWith(color: s.textMuted),
        );
      case 'Input' ||
          'TextArea' ||
          'Select' ||
          'DatePicker' ||
          'Slider' ||
          'CheckBoxGroup' ||
          'RadioGroup' ||
          'SwitchGroup' ||
          'Chips' ||
          'OptionCards':
        return _field(e, null);
      // ── Buttons
      case 'Buttons':
        final bs = [
          for (final b in _els(p['buttons'], 'Button').take(6)) _button(b),
        ];
        if (_str(p['direction']) == 'column') {
          return column(bs, spacing: 8);
        }
        return Wrap(spacing: 8, runSpacing: 8, children: bs);
      case 'Button':
        return Align(alignment: Alignment.centerLeft, child: _button(e));
      case 'Icon':
        return Align(
          alignment: Alignment.centerLeft,
          child: Icon(ouiIcon(_str(p['name'])), size: 20, color: s.text),
        );
      case 'IconButton':
        return Align(alignment: Alignment.centerLeft, child: _iconButton(e));
      // ── Lists
      case 'ListBlock':
        return _listBlock(e);
      case 'ListItem':
        return _listBlock(
          ElementNode(
            typeName: 'ListBlock',
            props: {
              'items': [e],
            },
          ),
        );
      case 'FollowUpBlock' || 'FollowUpItem':
        // Shown under the reply like Tove's suggestions (extractSuggestions).
        return const SizedBox.shrink();
      // ── Layout
      case 'SectionBlock':
        final secs = _els(p['sections'], 'SectionItem');
        if (p['isFoldable'] == false) {
          return column([
            for (final sec in secs)
              column([
                Semantics(
                  header: true,
                  child: Text(_str(sec.props['trigger']) ?? '', style: s.h4),
                ),
                _children(sec, 'content'),
              ], spacing: 8),
          ]);
        }
        return column([
          for (final sec in secs)
            UiDetailsView(
              title: _str(sec.props['trigger']) ?? '',
              initiallyOpen: true,
              style: s,
              body: _children(sec, 'content'),
            ),
        ], spacing: 0);
      case 'Tabs':
        final tabs = _els(p['items'], 'TabItem');
        return _OuiTabs(
          style: s,
          labels: [for (final t in tabs) _str(t.props['trigger']) ?? ''],
          panes: [for (final t in tabs) _children(t, 'content')],
        );
      case 'Accordion':
        return column([
          for (final it in _els(p['items'], 'AccordionItem'))
            UiDetailsView(
              title: _str(it.props['trigger']) ?? '',
              style: s,
              body: _children(it, 'content'),
            ),
        ], spacing: 0);
      case 'Steps':
        final steps = _els(p['items'], 'StepsItem');
        if (steps.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, st) in steps.indexed)
              _StepRow(
                index: i + 1,
                last: i == steps.length - 1,
                style: s,
                title: _str(st.props['title']) ?? '',
                body: _str(st.props['details']) == null
                    ? null
                    : _markdown(_str(st.props['details'])!),
              ),
          ],
        );
      case 'Carousel':
        return _carousel(e);
      // ── Data display
      case 'TagBlock':
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in _strs(p['tags']).take(20))
              _tag(t, UiTone.neutral, null, _str(p['size'])),
          ],
        );
      case 'Tag':
        return Align(alignment: Alignment.centerLeft, child: _tagOf(e));
      case 'EntityList':
        return _entityList(p);
      // ── Card blocks
      case 'SnippetCardBlock' ||
          'OverviewCardBlock' ||
          'ContextCardBlock' ||
          'CompositeCardBlock' ||
          'VisualCardBlock':
        return _cardBlock(e);
      case 'SnippetCardItem' ||
          'OverviewCardItem' ||
          'ContextCardItem' ||
          'CompositeCardItem' ||
          'VisualCardItem':
        return _cardItem(e, null);
      case 'Text' || 'BoldText':
        return _textLine(e);
      case 'IconText':
        return _iconText(p);
      case 'ImageText':
        return _imageText(p);
      case 'ImageTextLarge':
        return _imageTextLarge(p);
      case 'MetricIndicatorInline' || 'MetricIndicatorWithStrikethrough':
        return _metric(p, e.typeName == 'MetricIndicatorWithStrikethrough');
      // ── Tove
      case 'Email':
        final to = _strs(p['to']);
        final header = {
          'title': _str(p['subject']) ?? 'Email',
          'kind': 'email',
          'lang': 'text',
          'to': to,
          'subject': _str(p['subject']) ?? '',
          if (_strs(p['cc']).isNotEmpty) 'cc': _strs(p['cc']),
        };
        return ArtifactCard(
          body: '${jsonEncode(header)}\n${_str(p['body']) ?? ''}',
          complete: state.widget.complete,
          style: s,
        );
      case 'Artifact':
        final kind = _str(p['kind']) ?? 'code';
        final lang =
            _str(p['language']) ??
            (kind == 'draft' || kind == 'document' ? 'markdown' : 'text');
        final header = {
          'title': _str(p['title']) ?? 'Untitled',
          'kind': kind,
          'lang': lang,
          'file': ?_str(p['file']),
        };
        return ArtifactCard(
          body: '${jsonEncode(header)}\n${_str(p['content']) ?? ''}',
          complete: state.widget.complete,
          style: s,
        );
      case 'Checklist':
        final sections = [
          for (final sec in _els(p['sections'], 'ChecklistSection').take(8))
            UiCheckSection(
              title: _str(sec.props['title']),
              time: _str(sec.props['time']),
              icon: _str(sec.props['icon']),
              items: [
                for (final t in _strs(sec.props['items']).take(12))
                  UiCheckItem(t),
              ],
            ),
        ].where((x) => x.items.isNotEmpty).toList();
        if (sections.isEmpty) return const SizedBox.shrink();
        final sid = e.statementId ?? 'c$_count';
        return Builder(
          builder: (context) => UiElementView(
            style: s,
            element: UiChecklist(
              id: 'oui${UiBlockOrdinal.of(context)}.$sid',
              title: _str(p['title']),
              sections: sections,
            ),
          ),
        );
      case 'Entities':
        return UiElementView(
          style: s,
          element: UiEntities(
            items: [
              for (final x in _els(p['items'], 'Entity').take(6))
                () {
                  final img = _str(x.props['image']);
                  final ref = _entityRef(img);
                  return UiEntity(
                    name: _str(x.props['name']) ?? '',
                    sub: _str(x.props['subtitle']),
                    image: _isHttps(img) ? img : null,
                    about: _str(x.props['about']),
                    page: ref == null
                        ? null
                        : 'https://en.wikipedia.org/wiki/'
                              '${Uri.encodeComponent(ref.replaceAll(' ', '_'))}',
                  );
                }(),
            ],
          ),
        );
      case 'News':
        return UiElementView(
          style: s,
          element: UiNews(
            items: [
              for (final x in _els(p['items'], 'Article').take(8))
                if (_isHttps(_str(x.props['url'])))
                  UiNewsItem(
                    title: _str(x.props['title']) ?? '',
                    url: _str(x.props['url'])!,
                    source: _str(x.props['source']),
                    date: _str(x.props['date']),
                    image: _isHttps(_str(x.props['image']))
                        ? _str(x.props['image'])
                        : null,
                  ),
            ],
          ),
        );
      case 'Places' || 'Place':
        final items = e.typeName == 'Place'
            ? [e]
            : _els(p['items'], 'Place').take(10).toList();
        final places = [for (final x in items) ?_ouiPlace(x)];
        if (places.isEmpty) return const SizedBox.shrink();
        return OuiPlacesView(
          items: places,
          selection: state.placeSelection,
          style: s,
        );
      case 'Map':
        final places = [
          for (final x in _els(p['items']).take(20)) ?_ouiPlace(x),
        ];
        if (places.isEmpty) return const SizedBox.shrink();
        final zoom = p['zoom'] is num ? toNumber(p['zoom']).clamp(3, 18) : null;
        return OuiMapView(
          items: places,
          selection: state.placeSelection,
          style: s,
          zoom: zoom?.toDouble(),
        );
      case 'Pin':
        return const SizedBox.shrink(); // only inside a Map
      case 'LocationButton':
        return OuiLocationButton(
          label: _str(p['label']) ?? 'Use my location',
          style: s,
        );
      case 'Quiz' || 'Question':
        final questions = [
          for (final x
              in (e.typeName == 'Question'
                      ? [e]
                      : _els(p['questions'], 'Question'))
                  .take(40))
            ?_ouiQuestion(x),
        ];
        if (questions.isEmpty) return const SizedBox.shrink();
        final sid = e.statementId ?? 'q$_count';
        return Builder(
          builder: (context) => OuiQuizView(
            id: 'oui${UiBlockOrdinal.of(context)}.$sid',
            title: _str(p['title']) ?? 'Quiz',
            questions: questions,
            source: _str(p['source']),
            note: _str(p['note']),
            style: s,
          ),
        );
      case 'Status':
        return UiElementView(
          style: s,
          element: UiStatus(
            title: _str(p['title']) ?? '',
            state: _variantTone(p['variant']),
            summary: _str(p['summary']),
            updated: _str(p['updated']),
          ),
        );
      case 'Services':
        return UiElementView(
          style: s,
          element: UiServices(
            title: _str(p['title']),
            items: [
              for (final x in _els(p['items'], 'Service').take(20))
                UiService(
                  name: _str(x.props['name']) ?? '',
                  state: _variantTone(x.props['variant']),
                  latency: _str(x.props['latency']),
                  sub: _str(x.props['subtitle']),
                  ask: _str(x.props['ask']) == null
                      ? null
                      : cleanSendText(_str(x.props['ask'])!),
                ),
            ],
          ),
        );
      case 'Gauges':
        return UiElementView(
          style: s,
          element: UiGauges(
            items: [
              for (final x in _els(p['items'], 'Gauge').take(6))
                () {
                  final max = x.props['max'] is num
                      ? toNumber(x.props['max'])
                      : 100.0;
                  return UiGauge(
                    label: _str(x.props['label']) ?? '',
                    value: toNumber(x.props['value']),
                    max: max <= 0 ? 100 : max,
                    unit: _str(x.props['unit']) ?? (max == 100 ? '%' : ''),
                    tone: _variantTone(x.props['variant']),
                  );
                }(),
            ],
          ),
        );
    }
    return const SizedBox.shrink();
  }

  OuiPlace? _ouiPlace(ElementNode x) {
    final q = x.props;
    if (x.typeName == 'Pin') {
      final lat = q['lat'], lng = q['lng'];
      final label = _str(q['label']);
      if (label == null || lat is! num || lng is! num) return null;
      if (lat.abs() > 90 || lng.abs() > 180) return null;
      return OuiPlace(
        ref: '',
        name: label,
        lat: lat.toDouble(),
        lng: lng.toDouble(),
      );
    }
    if (x.typeName != 'Place') return null;
    final name = _str(q['name']);
    if (name == null) return null;
    final ref = _str(q['id']) ?? '';
    return OuiPlace(
      ref: isPlaceRef(ref) ? ref : '',
      name: name,
      subtitle: _str(q['subtitle']),
      facts: _str(q['facts']),
      rating: _str(q['rating']),
      ratingSource: _str(q['ratingSource']),
      phone: _str(q['phone']),
      url: _isHttps(_str(q['url'])) ? _str(q['url']) : null,
    );
  }

  OuiQuestion? _ouiQuestion(ElementNode x) {
    final text = _str(x.props['text']);
    final options = _strs(x.props['options']).take(8).toList();
    if (text == null || options.length < 2) return null;
    final a = x.props['answer'];
    final answer = a is num && a >= 0 && a < options.length ? a.toInt() : null;
    return OuiQuestion(
      text: text,
      options: options,
      answer: answer,
      explain: _str(x.props['explain']),
    );
  }

  // ── Root card and sources

  Widget _rootCard(ElementNode e) {
    final kids = [for (final c in _els(e.props['children'])) node(c)];
    final sources = [
      for (final x
          in (e.props['sources'] is List
              ? e.props['sources']! as List
              : const []))
        if (x is Map && _isHttps(_str(x['url'])))
          (
            title: _str(x['title']) ?? _str(x['url'])!,
            site: _str(x['sourceName']),
            url: _str(x['url'])!,
          ),
    ].take(10).toList();
    if (sources.isNotEmpty) {
      kids.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sources', style: s.caption),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, src) in sources.indexed)
                  SourcePill(
                    label: '${i + 1}. ${src.site ?? _host(src.url)}',
                    semanticsLabel:
                        '${src.title}, ${src.site ?? _host(src.url)}',
                    icon: Icons.link_rounded,
                    style: s,
                    onTap: () => h.openLink(src.url),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return column(kids);
  }

  String _host(String u) {
    final uri = Uri.tryParse(u);
    return uri == null ? u : linkHost(uri);
  }

  /// `[1]` citations (not links) become superscripts.
  String _citations(String t) => t.replaceAllMapped(
    RegExp(r'\[(\d{1,2})\](?![(\[:])'),
    (m) => '<sup>${m[1]}</sup>',
  );

  Widget _textContent(String text, String? size) {
    if (size == null || size == 'default') return _markdown(_citations(text));
    final plain = text.replaceAll(RegExp(r'\*\*|__'), '');
    final st = switch (size) {
      'small' => s.caption.copyWith(color: s.text),
      'small-heavy' => s.caption.copyWith(
        color: s.text,
        fontWeight: FontWeight.w600,
      ),
      'large' => s.h4.copyWith(fontWeight: FontWeight.w400),
      'large-heavy' => s.h4,
      _ => s.body,
    };
    return Text(plain, style: st);
  }

  /// OpenUI's Callout: a 2 px coloured edge, a coloured bold title.
  Widget _edgeCallout(UiTone tone, String? title, String? body) {
    final c = tone == UiTone.neutral ? s.text : _toneColor(tone);
    return Semantics(
      container: true,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: c, width: 2)),
        ),
        padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Text(title, style: s.bodyStrong.copyWith(color: c)),
            if (body != null) _markdown(body),
          ],
        ),
      ),
    );
  }

  // ── Table

  Widget _table(List<ElementNode> cols) {
    if (cols.isEmpty) return const SizedBox.shrink();
    List<Object?> data(ElementNode c) =>
        c.props['data'] is List ? c.props['data']! as List : const [];
    final n = cols
        .map((c) => data(c).length)
        .fold<int>(0, math.max)
        .clamp(0, 60);
    String cell(Object? v) =>
        (_str(v) ?? '').replaceAll('|', r'\|').replaceAll('\n', ' ');
    final numeric = [for (final c in cols) _str(c.props['type']) == 'number'];
    final b = StringBuffer()
      ..writeln('| ${cols.map((c) => cell(c.props['label'])).join(' | ')} |')
      ..writeln(
        '|${[for (final n in numeric) n ? ' ---: ' : ' --- '].join('|')}|',
      );
    for (var i = 0; i < n; i++) {
      b.writeln(
        '| ${[for (final c in cols) cell(i < data(c).length ? data(c)[i] : null)].join(' | ')} |',
      );
    }
    return _markdown(b.toString());
  }

  // ── Forms

  Widget _formView(ElementNode e) {
    final prevForm = _form, prevFields = _fields;
    _form = _str(e.props['name']) ?? 'form';
    _fields = [];
    final fields = [for (final f in _els(e.props['fields'])) node(f)];
    final buttons = e.props['buttons'] is ElementNode
        ? node(e.props['buttons'])
        : Align(
            alignment: Alignment.centerLeft,
            child: _button(
              ElementNode(
                typeName: 'Button',
                props: {'label': 'Submit', 'variant': 'primary'},
              ),
            ),
          );
    state._formMeta[_form] = _fields!;
    final out = Container(
      decoration: _frame(),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: column([...fields, buttons], spacing: 16),
    );
    _form = prevForm;
    _fields = prevFields;
    return out;
  }

  Widget _formControl(ElementNode e) {
    final label = _str(e.props['label']);
    final hint = _str(e.props['hint']);
    final input = e.props['input'];
    final name = input is ElementNode ? _str(input.props['name']) : null;
    final error =
        name != null && (state._errors[_form]?.contains(name) ?? false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) ...[
          Text(label, style: s.body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
        ],
        if (input is ElementNode) _field(input, label),
        if (error)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Required', style: s.caption.copyWith(color: s.danger)),
          )
        else if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(hint, style: s.caption),
          ),
      ],
    );
  }

  /// One form input. Its value lives under (form, name); a `$binding`
  /// value mirrors it into the block's state.
  Widget _field(ElementNode e, String? label) {
    final p = e.props;
    final form = _form;
    final name = _str(p['name']) ?? e.typeName.toLowerCase();
    final target = _bound(p['value']);
    final rules = p['rules'];
    final required =
        rules is Map && truthy(rules['required']) ||
        rules is List && rules.contains('required');
    _fields?.add(
      _FieldMeta(name, label ?? _str(p['label']) ?? name, required, e.typeName),
    );
    Object? read() {
      if (target != null && state._store.containsKey(target)) {
        return state._store[target];
      }
      return state._fieldValue(form, name);
    }

    void write(Object? v) {
      state._setField(form, name, v);
      if (target != null) state._write(target, v);
    }

    switch (e.typeName) {
      case 'Input' || 'TextArea':
        return _OuiTextField(
          key: ValueKey('in:$form/$name'),
          style: s,
          hint: _str(p['placeholder']),
          value: _str(read()) ?? '',
          lines: e.typeName == 'TextArea'
              ? (p['rows'] is num ? toNumber(p['rows']).toInt().clamp(2, 8) : 3)
              : 1,
          keyboard: switch (_str(p['type'])) {
            'email' => TextInputType.emailAddress,
            'number' => TextInputType.number,
            'url' => TextInputType.url,
            _ => null,
          },
          obscure: _str(p['type']) == 'password',
          onChanged: (t) => write(t),
        );
      case 'Select':
        final items = [
          for (final it in _els(p['items'], 'SelectItem').take(12))
            (
              value: _str(it.props['value']) ?? '',
              label: _str(it.props['label']) ?? _str(it.props['value']) ?? '',
            ),
        ];
        final cur = _str(read());
        return _choicePills(
          [for (final i in items) (i.value, i.label, null)],
          {?cur},
          (v) => write(v),
          multi: false,
        );
      case 'Chips':
        final multi = _str(p['type']) == 'multiple';
        final items = [
          for (final it in _els(p['items'], 'ChipItem').take(12))
            if (!truthy(it.props['disabled']))
              (
                _str(it.props['value']) ?? '',
                _str(it.props['label']) ?? '',
                _iconOf(it.props['icon']),
              ),
        ];
        final cur = read() ?? p['defaultValue'];
        return _choicePills(
          items,
          {
            if (cur is List) ...cur.map((x) => _str(x) ?? ''),
            if (cur is String) cur,
          },
          (v) {
            if (!multi) return write(v);
            final now = {
              if (cur is List) ...cur.map((x) => _str(x) ?? ''),
              if (cur is String) cur,
            };
            if (!now.remove(v)) now.add(v);
            write(now.toList());
          },
          multi: multi,
        );
      case 'OptionCards':
        return _optionCards(e, read() ?? p['defaultValue'], write);
      case 'RadioGroup':
        final cur = _str(read() ?? p['defaultValue']);
        return column([
          for (final it in _els(p['items'], 'RadioItem').take(10))
            _choiceRow(
              title: _str(it.props['label']) ?? '',
              sub: _str(it.props['description']),
              selected: _str(it.props['value']) == cur,
              radio: true,
              onTap: () => write(_str(it.props['value'])),
            ),
        ], spacing: 4);
      case 'CheckBoxGroup' || 'SwitchGroup':
        final sw = e.typeName == 'SwitchGroup';
        final items = _els(
          p['items'],
          sw ? 'SwitchItem' : 'CheckBoxItem',
        ).take(12).toList();
        final raw = read();
        final cur = <String, bool>{
          for (final it in items)
            _str(it.props['name']) ?? '': truthy(it.props['defaultChecked']),
          if (raw is Map)
            for (final en in raw.entries) '${en.key}': truthy(en.value),
        };
        void flip(String k) => write({...cur, k: !(cur[k] ?? false)});
        return column([
          for (final it in items)
            sw
                ? MergeSemantics(
                    child: Row(
                      children: [
                        Expanded(
                          child: _titleSub(
                            _str(it.props['label']) ??
                                _str(it.props['name']) ??
                                '',
                            _str(it.props['description']),
                          ),
                        ),
                        Switch.adaptive(
                          value: cur[_str(it.props['name']) ?? ''] ?? false,
                          onChanged: (_) => flip(_str(it.props['name']) ?? ''),
                        ),
                      ],
                    ),
                  )
                : _choiceRow(
                    title: _str(it.props['label']) ?? '',
                    sub: _str(it.props['description']),
                    selected: cur[_str(it.props['name']) ?? ''] ?? false,
                    radio: false,
                    onTap: () => flip(_str(it.props['name']) ?? ''),
                  ),
        ], spacing: 4);
      case 'Slider':
        return _sliderField(
          p,
          read,
          write,
          label == null ? _str(p['label']) : null,
        );
      case 'DatePicker':
        return _datePicker(
          _str(read()),
          _str(p['mode']) == 'range',
          (v) => write(v),
        );
    }
    return const SizedBox.shrink();
  }

  Widget _titleSub(String title, String? sub) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: s.body),
      if (sub != null) Text(sub, style: s.caption),
    ],
  );

  Widget _choiceRow({
    required String title,
    String? sub,
    required bool selected,
    required bool radio,
    required VoidCallback onTap,
  }) {
    final on = HermesTokens.of(state.context);
    return Semantics(
      checked: radio ? null : selected,
      inMutuallyExclusiveGroup: radio,
      selected: radio ? selected : null,
      button: true,
      child: InkWell(
        onTap: () {
          h.selectionHaptic();
          onTap();
        },
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: sub == null
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 20,
                  height: 20,
                  margin: EdgeInsets.only(top: sub == null ? 0 : 2),
                  decoration: BoxDecoration(
                    shape: radio ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: radio ? null : BorderRadius.circular(5),
                    color: selected && !radio ? on.accent : null,
                    border: Border.all(
                      color: selected ? on.accent : s.outline,
                      width: selected && radio ? 6 : 1.5,
                    ),
                  ),
                  child: selected && !radio
                      ? Icon(Icons.check_rounded, size: 14, color: on.onAccent)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(child: _titleSub(title, sub)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _choicePills(
    List<(String, String, IconData?)> items,
    Set<String> selected,
    ValueChanged<String> onPick, {
    required bool multi,
  }) => DrawerSwipeExclusion(
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (v, l, icon) in items)
          UiPill(
            label: l,
            style: s,
            quiet: true,
            leading: icon,
            selected: selected.contains(v),
            semanticsSelected: selected.contains(v),
            onTap: () {
              h.selectionHaptic();
              onPick(v);
            },
          ),
      ],
    ),
  );

  Widget _optionCards(
    ElementNode e,
    Object? cur,
    void Function(Object?) write,
  ) {
    final multi = _str(e.props['type']) == 'multiple';
    final sel = {
      if (cur is List) ...cur.map((x) => _str(x) ?? ''),
      if (cur is String) cur,
    };
    final cards = [
      for (final it in _els(e.props['items'], 'OptionCard').take(8))
        () {
          final v = _str(it.props['value']) ?? '';
          final on = sel.contains(v);
          final top = it.props['topContent'];
          final disabled = truthy(it.props['disabled']);
          return Semantics(
            selected: on,
            button: true,
            enabled: !disabled,
            child: InkWell(
              borderRadius: BorderRadius.circular(s.frameRadius + 4),
              onTap: disabled
                  ? null
                  : () {
                      h.selectionHaptic();
                      if (!multi) return write(v);
                      final next = Set.of(sel);
                      if (!next.remove(v)) next.add(v);
                      write(next.toList());
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: _frame(border: on ? accent : null).copyWith(
                  border: Border.all(
                    color: on ? accent : s.outline,
                    width: on ? 1.5 : 1,
                  ),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (top is ElementNode && top.typeName == 'Icon')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Icon(
                          ouiIcon(_str(top.props['name'])),
                          size: 22,
                          color: s.text,
                        ),
                      ),
                    if (top is ElementNode &&
                        top.typeName == 'Image' &&
                        _picture(top.props['src']))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _image(
                          _str(top.props['src'])!,
                          height: 88,
                          radius: 10,
                        ),
                      ),
                    Text(_str(it.props['title']) ?? '', style: s.bodyStrong),
                    if (_str(it.props['subtitle']) != null)
                      Text(_str(it.props['subtitle'])!, style: s.caption),
                  ],
                ),
              ),
            ),
          );
        }(),
    ];
    return _grid(cards, 2);
  }

  Widget _sliderField(
    Map<String, Object?> p,
    Object? Function() read,
    void Function(Object?) write,
    String? label,
  ) {
    final min = toNumber(p['min']);
    var max = toNumber(p['max']);
    if (max <= min) max = min + 1;
    final step = p['step'] is num && toNumber(p['step']) > 0
        ? toNumber(p['step'])
        : (max - min) / 100;
    final raw = read();
    final dv = p['defaultValue'];
    final first = raw is List
        ? (raw.isEmpty ? null : raw.first)
        : raw ?? (dv is List && dv.isNotEmpty ? dv.first : dv);
    final v = (first == null ? min : toNumber(first))
        .clamp(min, max)
        .toDouble();
    final asList = raw is List || (raw == null && dv is List);
    final shown = jsString(v);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: label == null
                  ? const SizedBox()
                  : Text(label, style: s.body),
            ),
            Text(shown, style: _strong),
          ],
        ),
        UiSlider(
          value: v,
          min: min,
          max: max,
          step: step,
          active: s.text,
          inactive: s.text.withValues(alpha: 0.12),
          thumbFill: s.background,
          thumbRing: s.text.withValues(alpha: 0.3),
          semanticLabel: label ?? _str(p['name']),
          semanticValue: shown,
          onChanged: (nv) {
            h.selectionHaptic();
            write(asList ? [nv] : nv);
          },
        ),
      ],
    );
  }

  Widget _datePicker(String? cur, bool range, ValueChanged<String> write) {
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Builder(
      builder: (context) => Align(
        alignment: Alignment.centerLeft,
        child: UiPill(
          label: cur ?? (range ? 'Pick dates' : 'Pick a date'),
          style: s,
          quiet: true,
          leading: Icons.event_outlined,
          onTap: () async {
            final now = DateTime.now();
            final first = DateTime(now.year - 5), last = DateTime(now.year + 5);
            if (range) {
              final r = await showDateRangePicker(
                context: context,
                firstDate: first,
                lastDate: last,
              );
              if (r != null) write('${fmt(r.start)} – ${fmt(r.end)}');
            } else {
              final d = await showDatePicker(
                context: context,
                firstDate: first,
                lastDate: last,
                initialDate: now,
              );
              if (d != null) write(fmt(d));
            }
          },
        ),
      ),
    );
  }

  // ── Buttons

  bool _sends(Object? action) {
    if (action == null) return true;
    return _steps(action).any((x) => x is ToAssistantStep);
  }

  List<ActionStep> _steps(Object? action) => [
    if (action is ActionPlan) ...action.steps,
    if (action is List)
      for (final a in action)
        if (a is ActionPlan) ...a.steps,
  ];

  Widget _button(ElementNode e) {
    final label = _str(e.props['label']) ?? '';
    final action = e.props['action'];
    final sends = _sends(action);
    final form = _form.isEmpty ? null : _form;
    final enabled =
        !sends || (h.canSend && !state._sent && h.nextUserMessage == null);
    final variant = _str(e.props['variant']);
    final primary = variant == 'primary';
    return UiPill(
      label: label,
      style: s,
      primary: primary,
      quiet: !primary,
      height:
          _str(e.props['size']) == 'small' ||
              _str(e.props['size']) == 'extra-small'
          ? 34
          : 40,
      onTap: enabled
          ? () => form != null && sends
                ? state._submit(form, action, label, h)
                : state._run(action, label, h)
          : null,
    );
  }

  Widget _iconButton(ElementNode e) {
    final name = _str(e.props['name']) ?? '';
    final action = e.props['action'];
    final enabled =
        !_sends(action) ||
        (h.canSend && !state._sent && h.nextUserMessage == null);
    final primary = _str(e.props['variant']) == 'primary';
    final on = HermesTokens.of(state.context);
    return Semantics(
      button: true,
      label: name,
      child: InkResponse(
        onTap: enabled ? () => state._run(action, name, h) : null,
        radius: 24,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: _str(e.props['shape']) == 'square'
                ? BoxShape.rectangle
                : BoxShape.circle,
            borderRadius: _str(e.props['shape']) == 'square'
                ? BorderRadius.circular(10)
                : null,
            color: primary ? on.accent : null,
            border: primary ? null : Border.all(color: s.outline),
          ),
          child: Icon(
            _iconOf(e.props['icon']) ?? Icons.circle_outlined,
            size: 20,
            color: primary ? on.onAccent : s.text,
          ),
        ),
      ),
    );
  }

  IconData? _iconOf(Object? v) => v is ElementNode
      ? ouiIcon(_str(v.props['name']))
      : _str(v) == null
      ? null
      : ouiIcon(_str(v));

  // ── Lists

  Widget _listBlock(ElementNode e) {
    final items = _els(e.props['items'], 'ListItem').take(20).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final image = _str(e.props['variant']) == 'image';
    final small = _str(e.props['size']) == 'small';
    final rows = <Widget>[];
    for (final (i, it) in items.indexed) {
      final p = it.props;
      final title = _str(p['title']) ?? '';
      final sub = _str(p['subtitle']);
      final img = p['image'] is Map
          ? _str((p['image']! as Map)['src'])
          : _str(p['image']);
      final action = p['action'];
      final tappable = action != null;
      final enabled =
          !_sends(action) ||
          (h.canSend && !state._sent && h.nextUserMessage == null);
      final box = sub == null || small ? 24.0 : 40.0;
      final indicator = image && _isPicture(img)
          ? UiRemoteImageBox(
              url: img!,
              width: box,
              height: box,
              style: s,
              radius: 8,
            )
          : Container(
              width: box,
              height: box,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: s.outline),
                borderRadius: BorderRadius.circular(box > 24 ? 8 : 6),
              ),
              child: Text(
                '${i + 1}',
                style: s.caption.copyWith(color: s.textMuted),
              ),
            );
      Widget row = Row(
        crossAxisAlignment: sub == null
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: sub == null ? 0 : 2),
            child: indicator,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: small ? s.body : s.bodyStrong),
                if (sub != null)
                  Text(sub, style: s.body.copyWith(color: s.textMuted)),
              ],
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: 8),
            if (_str(p['actionLabel']) != null)
              Text(_str(p['actionLabel'])!, style: s.caption)
            else
              Icon(Icons.chevron_right_rounded, size: 20, color: s.textMuted),
          ],
        ],
      );
      if (tappable) {
        row = Semantics(
          button: true,
          enabled: enabled,
          child: InkWell(
            onTap: enabled ? () => state._run(action, title, h) : null,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: row,
              ),
            ),
          ),
        );
      }
      if (i > 0 && tappable) {
        rows.add(Divider(height: 1, thickness: 1, color: s.hairline));
      }
      rows.add(row);
    }
    final anyTap = items.any((it) => it.props['action'] != null);
    return column(rows, spacing: anyTap ? 0 : (small ? 12 : 18));
  }

  // ── Carousel

  Widget _carousel(ElementNode e) {
    final raw = e.props['children'];
    final slides = <List<Object?>>[
      if (raw is List)
        for (final x in raw)
          if (x is List) x else if (x is ElementNode) [x],
    ].take(12).toList();
    if (slides.isEmpty) return const SizedBox.shrink();
    return DrawerSwipeExclusion(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, sl) in slides.indexed) ...[
              if (i > 0) const SizedBox(width: 12),
              Container(
                width: 252,
                decoration: _frame(),
                padding: const EdgeInsets.all(12),
                child: column([for (final x in sl) node(x)], spacing: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Tags and rows

  Widget _tagOf(ElementNode e) => _tag(
    _str(e.props['text']) ?? '',
    _variantTone(e.props['variant']),
    _iconOf(e.props['icon']),
    _str(e.props['size']),
  );

  Widget _tag(String text, UiTone tone, IconData? icon, String? size) {
    final neutral = tone == UiTone.neutral;
    final c = neutral ? s.text : _toneColor(tone);
    final h = switch (size) {
      'md' => 32.0,
      'lg' => 36.0,
      _ => 24.0,
    };
    return Container(
      height: h,
      padding: EdgeInsets.symmetric(horizontal: size == 'lg' ? 12 : 8),
      decoration: BoxDecoration(
        color: neutral ? null : c.withValues(alpha: 0.12),
        border: neutral ? Border.all(color: s.outline) : null,
        borderRadius: BorderRadius.circular(size == 'lg' ? 8 : 6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: s.caption.copyWith(color: c, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entityList(Map<String, Object?> p) {
    final small = _str(p['size']) == 'small';
    ({String l, String r, bool n})? row(Object? x) => x is Map
        ? (
            l: _str(x['left']) ?? '',
            r: _str(x['right']) ?? '',
            n: _str(x['rightVariant']) == 'number',
          )
        : null;
    final rows = [
      for (final x in (p['rows'] is List ? p['rows']! as List : const []).take(
        30,
      ))
        ?row(x),
    ];
    final head = small ? null : row(p['header']);
    final foot = small ? null : row(p['footer']);
    if (rows.isEmpty && head == null) return const SizedBox.shrink();
    final base = small ? s.caption.copyWith(color: s.text) : s.body;
    Widget line(
      ({String l, String r, bool n}) x, {
      bool header = false,
      bool footer = false,
    }) => Padding(
      padding: EdgeInsets.symmetric(vertical: small ? 8 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              x.l,
              style: header ? base.copyWith(color: s.textMuted) : base,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              x.r,
              textAlign: TextAlign.end,
              style:
                  (header
                          ? base.copyWith(color: s.textMuted)
                          : footer
                          ? s.h4
                          : base.copyWith(fontWeight: FontWeight.w600))
                      .copyWith(
                        fontFeatures: x.n
                            ? const [FontFeature.tabularFigures()]
                            : null,
                      ),
            ),
          ),
        ],
      ),
    );
    final all = [
      if (head != null) line(head, header: true),
      for (final r in rows) line(r),
      if (foot != null) line(foot, footer: true),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, w) in all.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: s.hairline),
          w,
        ],
      ],
    );
  }

  // ── Card blocks

  Widget _cardBlock(ElementNode e) {
    final type = e.typeName.replaceAll('Block', 'Item');
    final items = _els(e.props['items'], type).take(12).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final action = e.props['action'];
    final cards = [for (final it in items) _cardItem(it, action)];
    final carousel =
        _str(e.props['layout']) == 'carousel' ||
        (type == 'VisualCardItem' && items.length > 2);
    if (carousel) {
      final w = type == 'VisualCardItem' ? 220.0 : 240.0;
      return DrawerSwipeExclusion(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, c) in cards.indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                SizedBox(width: w, child: c),
              ],
            ],
          ),
        ),
      );
    }
    return _grid(cards, items.length == 1 ? 1 : 2, equalHeight: true);
  }

  String? _itemTitle(ElementNode it) {
    for (final k in ['lhs', 'top', 'header', 'body', 'title']) {
      final v = it.props[k];
      if (v is ElementNode) {
        final t =
            _str(v.props['title']) ??
            _str(v.props['value']) ??
            _str(v.props['text']);
        if (t != null) return t;
      } else if (_str(v) != null) {
        return _str(v);
      }
    }
    return _str(it.props['id']);
  }

  Widget _cardItem(ElementNode it, Object? blockAction) {
    final p = it.props;
    Widget body;
    var pad = const EdgeInsets.all(12);
    var clip = false;
    switch (it.typeName) {
      case 'SnippetCardItem':
        body = Row(
          children: [
            Expanded(child: node(p['lhs'])),
            if (p['rhs'] != null) ...[const SizedBox(width: 8), node(p['rhs'])],
          ],
        );
      case 'OverviewCardItem':
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            node(p['top']),
            if (p['bottom'] != null) ...[
              const SizedBox(height: 18),
              node(p['bottom']),
            ],
          ],
        );
      case 'ContextCardItem':
        final title = p['title'];
        final bg = _str(p['bgImageSrc']);
        final text = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title is ElementNode)
              _tagOf(title)
            else if (_str(title) != null)
              Text(
                _str(title)!,
                style: s.caption.copyWith(
                  color: _isPicture(bg) ? Colors.white : s.textMuted,
                ),
              ),
            if (_str(p['body']) != null) ...[
              const SizedBox(height: 6),
              _isPicture(bg)
                  ? Text(
                      _str(p['body'])!.replaceAll('**', ''),
                      style: s.bodyStrong.copyWith(color: Colors.white),
                    )
                  : _markdown(_str(p['body'])!),
            ],
          ],
        );
        if (_isPicture(bg)) {
          clip = true;
          pad = EdgeInsets.zero;
          body = _photoCard(bg!, text, minHeight: 150);
        } else {
          body = text;
        }
      case 'CompositeCardItem':
        final header = p['header'];
        final footer = p['footer'] is Map ? p['footer']! as Map : const {};
        final bannerHeader =
            header is ElementNode &&
            (header.typeName == 'ImageTextLarge' || header.typeName == 'Image');
        clip = bannerHeader;
        pad = bannerHeader ? EdgeInsets.zero : pad;
        final inner = column([
          for (final b in _els(p['body'])) node(b),
          if (footer['price'] != null || footer['button'] != null)
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (footer['price'] != null) node(footer['price']),
                if (footer['button'] is ElementNode)
                  _button(footer['button']! as ElementNode),
              ],
            ),
        ], spacing: 10);
        if (bannerHeader) {
          final src = _str(header.props['src']);
          body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isPicture(src)) _image(src!, height: 150, radius: 0),
              Padding(
                padding: const EdgeInsets.all(12),
                child: column([
                  if (header.typeName == 'ImageTextLarge')
                    _titleBlock(header.props, large: true),
                  inner,
                ], spacing: 10),
              ),
            ],
          );
        } else {
          body = column([if (header != null) node(header), inner], spacing: 10);
        }
      case 'VisualCardItem':
        final bg = _str(p['bgImageSrc']);
        final tag = p['tag'];
        final b = p['body'];
        clip = true;
        pad = EdgeInsets.zero;
        final text = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (b is ElementNode) ...[
              Text(
                _value(b.props) ?? '',
                style: s.bodyStrong.copyWith(color: Colors.white),
              ),
              if (_str(b.props['subtext']) != null)
                Text(
                  _str(b.props['subtext'])!,
                  style: s.caption.copyWith(color: Colors.white70),
                ),
            ],
          ],
        );
        body = _photoCard(
          bg,
          text,
          minHeight: 220,
          top: tag is ElementNode ? _tagOf(tag) : null,
        );
      default:
        body = const SizedBox.shrink();
    }
    final card = Container(
      decoration: _frame(),
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      padding: pad,
      child: body,
    );
    if (blockAction == null) return card;
    final title = _itemTitle(it) ?? '';
    final enabled =
        !_sends(blockAction) ||
        (h.canSend && !state._sent && h.nextUserMessage == null);
    return Semantics(
      button: true,
      enabled: enabled,
      child: InkWell(
        borderRadius: BorderRadius.circular(s.frameRadius + 4),
        onTap: enabled
            ? () => state._run(blockAction, title, h, item: title)
            : null,
        child: card,
      ),
    );
  }

  /// A picture filling the card with a dark gradient for white text.
  Widget _photoCard(
    String? src,
    Widget text, {
    required double minHeight,
    Widget? top,
  }) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: minHeight),
    child: Stack(
      fit: StackFit.passthrough,
      children: [
        if (_isPicture(src))
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) => UiRemoteImageBox(
                url: src!,
                width: c.maxWidth,
                height: c.maxHeight,
                style: s,
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.12),
                  Colors.black.withValues(alpha: _isPicture(src) ? 0.62 : 0.4),
                ],
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                top ?? const SizedBox(height: 1),
                SizedBox(height: minHeight * 0.3),
                text,
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _textLine(ElementNode e) {
    final p = e.props;
    final bold = e.typeName == 'BoldText';
    final number = _str(p['variant']) == 'number';
    var st = switch (_str(p['size'])) {
      'xs' => s.caption,
      'sm' => s.caption.copyWith(color: s.text),
      'lg' => s.h4.copyWith(fontWeight: bold ? null : FontWeight.w400),
      _ => s.body,
    };
    if (bold) st = st.copyWith(fontWeight: FontWeight.w600);
    if (number) {
      st = st.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    }
    final sub = _str(p['subtext']);
    Color subColor = s.textMuted;
    if (_str(p['subtextVariant']) == 'metric' && sub != null) {
      final t = sub.trimLeft();
      if (t.startsWith('+')) subColor = s.success;
      if (t.startsWith('-') || t.startsWith('−')) subColor = s.danger;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_value(p) ?? '', style: st),
        if (sub != null) Text(sub, style: s.caption.copyWith(color: subColor)),
      ],
    );
  }

  Widget _titleBlock(Map<String, Object?> p, {bool large = false}) {
    final bold = large || truthy(p['bold']);
    final sub = _str(p['subtitle']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_str(p['title']) ?? '', style: bold ? s.bodyStrong : s.body),
        if (sub != null) Text(sub, style: s.caption),
      ],
    );
  }

  Widget _iconText(Map<String, Object?> p) {
    final tone = _variantTone(p['iconVariant']);
    final c = tone == UiTone.neutral ? s.text : _toneColor(tone);
    final size = switch (_str(p['iconSize'])) {
      'xs' => 24.0,
      's' || 'sm' => 28.0,
      'l' || 'lg' => 40.0,
      'xl' => 48.0,
      _ => 32.0,
    };
    final badge = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone == UiTone.neutral ? null : c.withValues(alpha: 0.12),
        border: tone == UiTone.neutral ? Border.all(color: s.outline) : null,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Icon(
        _iconOf(p['icon']) ?? Icons.circle_outlined,
        size: size * 0.55,
        color: c,
      ),
    );
    if (_str(p['layout']) == 'vertical') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [badge, const SizedBox(height: 8), _titleBlock(p)],
      );
    }
    return Row(
      children: [
        badge,
        const SizedBox(width: 10),
        Expanded(child: _titleBlock(p)),
      ],
    );
  }

  Widget _imageText(Map<String, Object?> p) {
    final src = _str(p['src']);
    final size = (p['imageSize'] is num ? toNumber(p['imageSize']) : 40.0)
        .clamp(24.0, 96.0)
        .toDouble();
    final pic = _isPicture(src)
        ? UiRemoteImageBox(
            url: src!,
            width: size,
            height: size,
            style: s,
            radius: 8,
          )
        : SizedBox(width: size, height: size);
    if (_str(p['layout']) == 'vertical') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [pic, const SizedBox(height: 8), _titleBlock(p)],
      );
    }
    return Row(
      children: [
        pic,
        const SizedBox(width: 10),
        Expanded(child: _titleBlock(p)),
      ],
    );
  }

  Widget _imageTextLarge(Map<String, Object?> p) {
    final src = _str(p['src']);
    return column([
      if (_isPicture(src)) _image(src!, radius: 12),
      _titleBlock(p, large: true),
    ], spacing: 10);
  }

  Widget _metric(Map<String, Object?> p, bool strike) {
    final trend = p['trend'] is Map ? p['trend']! as Map : null;
    final up = _str(trend?['direction']) == 'up';
    final tv = trend == null ? null : toNumber(trend['value']);
    final prev = strike ? _str(p['previousValue']) : null;
    final sub = _str(p['subtext']);
    final tc = up ? s.success : s.danger;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 6,
          children: [
            Text(
              _str(p['value']) ?? '',
              style: s.statValue.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (prev != null)
              Text(
                prev,
                style: s.caption.copyWith(
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            if (tv != null && !tv.isNaN)
              Text(
                '${up ? '▲' : '▼'} ${uiNumber(tv.abs())}%',
                style: s.caption.copyWith(
                  color: tc,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        if (sub != null) Text(sub, style: s.caption),
      ],
    );
  }
}

class _FieldMeta {
  const _FieldMeta(this.name, this.label, this.required, this.type);
  final String name, label, type;
  final bool required;
}

/// [OuiChartData] for one of OpenUI's chart elements.
OuiChartData ouiChartData(ElementNode e) {
  final p = e.props;
  List<String> strs(Object? v) => [
    if (v is List)
      for (final x in v) ?_str(x),
  ];
  List<double> nums(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is num || x is String) toNumber(x),
  ];
  final series = [
    if (p['series'] is List)
      for (final x in p['series']! as List)
        if (x is ElementNode)
          OuiSeries(
            _str(x.props['category']) ?? _str(x.props['name']) ?? '',
            nums(x.props['values']).where((v) => !v.isNaN).take(60).toList(),
          ),
  ].take(6).toList();
  final variant = _str(p['variant']);
  final kind = switch (e.typeName) {
    'BarChart' => OuiChartKind.bar,
    'LineChart' => OuiChartKind.line,
    'AreaChart' => OuiChartKind.area,
    'HorizontalBarChart' => OuiChartKind.horizontalBar,
    'RadarChart' => OuiChartKind.radar,
    'PieChart' => OuiChartKind.pie,
    'RadialChart' => OuiChartKind.radial,
    'SingleStackedBarChart' => OuiChartKind.stackedBar,
    _ => OuiChartKind.scatter,
  };
  var labels = strs(p['labels']).take(60).toList();
  var values = nums(p['values']).where((v) => !v.isNaN).take(12).toList();
  // Older shape: slices: [Slice(category, value)].
  if (values.isEmpty && p['slices'] is List) {
    final slices = [
      for (final x in p['slices']! as List)
        if (x is ElementNode) x,
    ];
    labels = [for (final x in slices) _str(x.props['category']) ?? ''];
    values = [for (final x in slices) toNumber(x.props['value'])];
  }
  return OuiChartData(
    kind: kind,
    labels: labels,
    series: series,
    values: values,
    scatter: [
      if (p['datasets'] is List)
        for (final x in p['datasets']! as List)
          if (x is ElementNode)
            OuiScatter(
              _str(x.props['name']) ?? '',
              [
                if (x.props['points'] is List)
                  for (final pt in (x.props['points']! as List).take(200))
                    if (pt is ElementNode)
                      Offset(toNumber(pt.props['x']), toNumber(pt.props['y']))
                    else if (pt is Map)
                      Offset(toNumber(pt['x']), toNumber(pt['y'])),
              ].where((o) => o.dx.isFinite && o.dy.isFinite).toList(),
            ),
    ].take(4).toList(),
    stacked: variant == 'stacked',
    donut: variant == 'donut',
    semi: _str(p['appearance']) == 'semiCircular',
    step: variant == 'step',
    smooth: variant == 'natural',
    xLabel: _str(p['xLabel']),
    yLabel: _str(p['yLabel']),
    height: p['height'] is num ? toNumber(p['height']) : null,
  );
}
