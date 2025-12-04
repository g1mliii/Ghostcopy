import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'colors.dart';
import 'typography.dart';

/// Example usage of GhostCopy theme system
/// This file demonstrates how to use the design system components

class ThemeExampleScreen extends StatelessWidget {
  const ThemeExampleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GhostCopy Theme Example')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Typography Examples
            _buildSection(
              'Typography',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Headline', style: GhostTypography.headline),
                  const SizedBox(height: 8),
                  Text('Body Text', style: GhostTypography.body),
                  const SizedBox(height: 8),
                  Text('Caption', style: GhostTypography.caption),
                  const SizedBox(height: 8),
                  Text('Monospace Code', style: GhostTypography.mono),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Color Examples
            _buildSection(
              'Colors',
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _colorSwatch('Primary', GhostColors.primary),
                  _colorSwatch('Success', GhostColors.success),
                  _colorSwatch('Surface', GhostColors.surface),
                  _colorSwatch('Background', GhostColors.background),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Button Examples
            _buildSection(
              'Buttons',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Elevated Button'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {},
                    child: const Text('Text Button'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Input Examples
            _buildSection(
              'Input Fields',
              Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      hintText: 'Enter text here',
                      labelText: 'Label',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search...',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Glassmorphism Example
            _buildSection(
              'Glassmorphism',
              Container(
                height: 100,
                decoration: AppTheme.glassDecoration,
                padding: const EdgeInsets.all(16),
                child: const Center(
                  child: Text(
                    'Glass Container',
                    style: TextStyle(color: GhostColors.textPrimary),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Card Example
            _buildSection(
              'Cards',
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Card Title', style: GhostTypography.headline),
                      const SizedBox(height: 8),
                      Text(
                        'This is a card with the GhostCopy design system.',
                        style: GhostTypography.body.copyWith(
                          color: GhostColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GhostTypography.headline),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _colorSwatch(String name, Color color) {
    return Column(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: GhostColors.glassBorder),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          name,
          style: GhostTypography.caption.copyWith(
            color: GhostColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
