import 'package:flutter/material.dart';

import '../../core/feedback/motion.dart';

/// Velocità dello scorrimento automatico mentre si trascina un elemento
/// vicino ai bordi della lista: proporzionale a quanto l'elemento sporge
/// oltre il bordo (fino a ~20 px ogni 1000/[kReorderAutoScrollVelocity] ms,
/// cioè da pochi px/s appena tocca il bordo a ~1200 px/s ben oltre).
const double kReorderAutoScrollVelocity = 60;

/// Aspetto dell'elemento trascinato (moduli, argomenti, insegnamenti): si
/// solleva con un'ombra, cresce appena (3%) e prende un filo azzurro; al
/// rilascio torna giù. Con «Riduci animazioni» niente scala né transizione:
/// l'ombra c'è subito.
Widget liftProxy(Widget child, int index, Animation<double> animation) =>
    AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final reduce = reduceMotion(context);
        final v = reduce
            ? 1.0
            : Curves.easeOutCubic.transform(animation.value.clamp(0.0, 1.0));
        final scheme = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Transform.scale(
          scale: reduce ? 1 : 1 + 0.03 * v,
          child: Material(
            elevation: 12 * v,
            shadowColor: Colors.black.withValues(alpha: dark ? 0.8 : 0.35),
            color: Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.08 * v),
              scheme.surfaceContainerHigh,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: scheme.primary.withValues(alpha: 0.45 * v),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        );
      },
      child: child,
    );
