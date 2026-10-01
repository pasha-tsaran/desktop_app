import 'package:flutter/material.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../shell/destination.dart';

final class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({required this.destination, super.key});

  final AppDestination destination;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(KenaiSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              destination.label,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: KenaiSpacing.xl),
            Expanded(
              child: Card(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(destination.icon, size: 48),
                      const SizedBox(height: KenaiSpacing.md),
                      Text(
                        'Навигационный каркас',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: KenaiSpacing.sm),
                      const Text(
                        'Функции этого раздела появятся на следующем этапе.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
