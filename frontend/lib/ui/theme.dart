import 'package:flutter/material.dart';

/// Stable cross-platform hook for UI automation.
class TestId extends StatelessWidget {
  final String value;
  final Widget child;
  const TestId(this.value, {required this.child, super.key});

  @override
  Widget build(BuildContext context) =>
      Semantics(identifier: value, child: child);
}

const cream = Color(0xFFFFFAF3);
const paper = Color(0xFFFFFDF9);
const ink = Color(0xFF493020);
const muted = Color(0xFFA2978C);
const orange = Color(0xFFFF942F);
const gold = Color(0xFFFFBE4C);
const line = Color(0xFFF0E8DD);
ThemeData kitchenTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'NotoSansSC',
  scaffoldBackgroundColor: cream,
  colorScheme: ColorScheme.fromSeed(
    seedColor: orange,
    primary: orange,
    surface: paper,
    onSurface: ink,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 14, height: 1.65, color: ink),
    bodyLarge: TextStyle(fontSize: 15, height: 1.6, color: ink),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: cream,
    foregroundColor: ink,
    centerTitle: true,
    elevation: 0,
    titleTextStyle: TextStyle(
      fontFamily: 'NotoSansSC',
      fontSize: 17,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: paper,
    hintStyle: const TextStyle(color: muted, fontSize: 13),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: line),
    ),
  ),
  dividerColor: line,
  snackBarTheme: const SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: ink,
  ),
);

class CozyCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const CozyCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: paper,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Colors.white),
      boxShadow: const [
        BoxShadow(
          color: Color(0x08633C14),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Material(color: Colors.transparent, child: child),
  );
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? semanticIdentifier;
  const PrimaryButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
    this.semanticIdentifier,
  });
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: onPressed == null
            ? [line, line]
            : [gold, const Color(0xFFFFAD38)],
      ),
      borderRadius: BorderRadius.circular(28),
    ),
    child: SizedBox(
      height: 50,
      child: Semantics(
        identifier: semanticIdentifier,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(foregroundColor: ink),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20),
                const SizedBox(width: 8),
              ],
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    ),
  );
}

class Tag extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const Tag(this.label, {super.key, this.selected = false, this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(24),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? gold : const Color(0xFFFFF2E2),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: selected ? ink : muted,
          fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
        ),
      ),
    ),
  );
}

class PageBody extends StatelessWidget {
  final List<Widget> children;
  const PageBody({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: children,
      ),
    ),
  );
}

void toast(BuildContext context, Object message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message.toString().replaceFirst('Exception: ', '')),
      ),
    );
