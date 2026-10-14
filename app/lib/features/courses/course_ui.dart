import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/services/external_launcher.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/university_colors.dart';
import '../../models/course.dart';
import '../../models/university.dart';
import '../../widgets/common.dart';

/// Palette semplice per il colore identificativo del corso.
const List<int> kCoursePalette = [
  0xFF1565C0, // blu
  0xFFC62828, // rosso
  0xFF2E7D32, // verde
  0xFFEF6C00, // arancio
  0xFF6A1B9A, // viola
  0xFF00838F, // ciano
  0xFFAD1457, // magenta
  0xFF4E342E, // marrone
  0xFF558B2F, // verde oliva
  0xFF283593, // indaco
  0xFFF9A825, // giallo
  0xFF455A64, // grigio blu
];

/// Colore dell'università: quello salvato nel DB, altrimenti il predefinito.
Color universityColor(
  String? universityId,
  Map<String, University> universities,
) {
  final u = universityId == null ? null : universities[universityId];
  if (u != null) return Color(u.color);
  return UniversityColors.forId(universityId);
}

/// Colore del corso: personalizzato oppure quello dell'università.
Color courseColor(Course c, Map<String, University> universities) =>
    c.color != null
    ? Color(c.color!)
    : universityColor(c.universityId, universities);

String universityLabel(String? id, Map<String, University> universities) {
  if (id == null) return 'Altra università';
  return universities[id]?.shortName ?? id;
}

String semesterLabel(String? s) {
  if (s == null || s.trim().isEmpty) return 'Semestre non indicato';
  switch (s.trim().toLowerCase()) {
    case '1':
      return '1° semestre';
    case '2':
      return '2° semestre';
    case 'annuale':
      return 'Annuale';
  }
  return s;
}

String yearLabel(int? y) => y == null ? 'Anno non indicato' : '$y° anno';

/// Modalità d'esame salvate nel DB → etichetta.
const Map<String, String> kExamModes = {
  'scritto': 'Scritto',
  'orale': 'Orale',
  'scritto+orale': 'Scritto e orale',
  'altro': 'Altro',
};

String examModeLabel(String? m) => m == null ? '—' : (kExamModes[m] ?? m);

/// Formatta un numero senza decimali inutili (6.0 → "6", 7.5 → "7,5").
String formatNumber(num? v, {int decimals = 1}) {
  if (v == null) return '—';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(decimals).replaceAll('.', ',');
}

String formatCfu(double? cfu) =>
    cfu == null ? 'CFU n.d.' : '${formatNumber(cfu)} CFU';

/// Semestre ordinabile: 1, 2, annuale, altro.
int semesterOrder(String? s) {
  switch (s?.trim().toLowerCase()) {
    case '1':
      return 1;
    case '2':
      return 2;
    case 'annuale':
      return 3;
    case null:
    case '':
      return 9;
  }
  return 5;
}

IconData courseStatusIcon(CourseStatus s) {
  switch (s) {
    case CourseStatus.active:
      return Icons.play_circle_outline;
    case CourseStatus.toTake:
      return Icons.pending_actions_outlined;
    case CourseStatus.upcoming:
      return Icons.schedule_outlined;
    case CourseStatus.completed:
      return Icons.check_circle_outline;
    case CourseStatus.archived:
      return Icons.archive_outlined;
  }
}

class CourseStatusChip extends StatelessWidget {
  const CourseStatusChip(this.status, {super.key});
  final CourseStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      CourseStatus.active => const Color(0xFF1E88E5),
      CourseStatus.toTake => const Color(0xFFF57C00),
      CourseStatus.upcoming => const Color(0xFF7E57C2),
      CourseStatus.completed => const Color(0xFF2E7D32),
      CourseStatus.archived => scheme.outline,
    };
    return Tooltip(
      message: status.description,
      child: SmallBadge(
        label: status.label,
        color: color,
        icon: courseStatusIcon(status),
      ),
    );
  }
}

/// Piccola etichetta colorata (stato, tipo, lingua…).
class SmallBadge extends StatelessWidget {
  const SmallBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // testo e icona con contrasto ≥ 4,5:1 sul fondo; tinta originale dietro
    final fg = readableOn(color, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Difficoltà 0–5 in stelle (supporta le mezze stelle).
class DifficultyStars extends StatelessWidget {
  const DifficultyStars(this.value, {super.key, this.size = 18});
  final double value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Colors.amber.shade700;
    final v = value.clamp(0, 5).toDouble();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            v >= i
                ? Icons.star
                : (v >= i - 0.5 ? Icons.star_half : Icons.star_border),
            size: size,
            color: color,
          ),
        const SizedBox(width: 6),
        Text('${formatNumber(v)}/5'),
      ],
    );
  }
}

/// Selettore colore a palette. `null` = usa il colore dell'università.
class ColorPaletteField extends StatelessWidget {
  const ColorPaletteField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.defaultColor,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final Color defaultColor;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.onSurface;
    Widget swatch({
      required Color color,
      required bool selected,
      required VoidCallback onTap,
      String? tooltip,
      IconData? icon,
    }) {
      return Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? outline : Colors.transparent,
                width: 3,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 18)
                : (icon == null
                      ? null
                      : Icon(icon, color: Colors.white, size: 18)),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        swatch(
          color: defaultColor,
          selected: value == null,
          onTap: () => onChanged(null),
          tooltip: 'Colore dell\'università',
          icon: Icons.school,
        ),
        for (final c in kCoursePalette)
          swatch(
            color: Color(c),
            selected: value == c,
            onTap: () => onChanged(c),
          ),
      ],
    );
  }
}

/// Riga etichetta/valore usata nelle sezioni di dettaglio.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.child,
  });
  InfoRow.text({
    super.key,
    required this.icon,
    required this.label,
    required String? value,
  }) : child = Text(value == null || value.trim().isEmpty ? '—' : value);

  final IconData icon;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.outline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 2),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Apre un file/cartella locale mostrando l'eventuale errore senza crash.
Future<void> openLocalPath(BuildContext context, String path) async {
  final r = await ExternalLauncher.openPath(path);
  if (context.mounted) showLaunchResult(context, r);
}
