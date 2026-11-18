import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Builds the app theme from [HermesTokens] (spec §3). Dark is the default.
/// [type] defaults to this platform's typeface ([HermesTypeface.forPlatform]).
ThemeData buildTheme(Brightness brightness, {HermesTypeface? type}) {
  final t =
      (brightness == Brightness.dark
              ? HermesTokens.darkTokens
              : HermesTokens.lightTokens)
          .withType(
            type ??
                HermesTypeface.forPlatform(defaultTargetPlatform, web: kIsWeb),
          );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.accent,
        brightness: brightness,
      ).copyWith(
        primary: t.accent,
        onPrimary: t.onAccent,
        secondary: t.accent,
        surface: t.bg,
        onSurface: t.text,
        onSurfaceVariant: t.textMuted,
        outline: t.outline,
        outlineVariant: t.hairline,
        error: t.danger,
        surfaceContainerLowest: t.bg,
        surfaceContainerLow: t.bgRaised,
        surfaceContainer: t.surface,
        surfaceContainerHigh: t.surfaceHigh,
        surfaceContainerHighest: t.surfaceHigh,
        surfaceTint: Colors.transparent,
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: t.typeface.family,
    fontFamilyFallback: t.typeface.fallback,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    extensions: [t],
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.constantTurbulenceSeedSplashFactory,
  );
  final focusRing = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Rad.field),
    borderSide: BorderSide(color: t.accent, width: 2),
  );
  final noBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Rad.field),
    borderSide: BorderSide.none,
  );
  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          bodyColor: t.text,
          displayColor: t.text,
          fontFamily: t.typeface.family,
        )
        .copyWith(bodyLarge: t.body, bodyMedium: t.row, titleMedium: t.title),
    appBarTheme: AppBarTheme(
      backgroundColor: t.bg,
      foregroundColor: t.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: t.title,
      systemOverlayStyle: t.dark
          ? SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: Colors.transparent,
            ),
    ),
    dividerTheme: DividerThemeData(color: t.hairline, space: 1, thickness: 1),
    iconTheme: IconThemeData(color: t.text, size: 24),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surface,
      border: noBorder,
      enabledBorder: noBorder,
      disabledBorder: noBorder,
      focusedBorder: focusRing,
      errorBorder: noBorder,
      focusedErrorBorder: focusRing.copyWith(
        borderSide: BorderSide(color: t.danger, width: 2),
      ),
      labelStyle: t.row.copyWith(color: t.textMuted),
      floatingLabelStyle: t.label.copyWith(color: t.textMuted),
      hintStyle: t.body.copyWith(color: t.textFaint),
      helperStyle: t.label.copyWith(color: t.textMuted),
      errorStyle: t.label.copyWith(color: t.danger),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: t.accent,
      selectionColor: t.accent.withValues(alpha: 0.35),
      selectionHandleColor: t.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        disabledBackgroundColor: t.accent.withValues(alpha: 0.4),
        disabledForegroundColor: t.onAccent.withValues(alpha: 0.7),
        minimumSize: const Size(64, 52),
        textStyle: t.row.copyWith(fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.accent,
        minimumSize: const Size(48, 48),
        textStyle: t.row.copyWith(fontWeight: FontWeight.w600),
        shape: const StadiumBorder(),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.accent : t.surfaceHigh,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.onAccent : t.textMuted,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.accent),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      textStyle: t.label.copyWith(color: t.text),
      waitDuration: const Duration(milliseconds: 600),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: t.title,
      contentTextStyle: t.row.copyWith(
        color: t.textMuted,
        fontWeight: FontWeight.w400,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(3),
      radius: const Radius.circular(2),
      thumbColor: WidgetStatePropertyAll(t.textFaint),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
