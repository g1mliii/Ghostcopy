import 'package:flutter/material.dart';
import '../../services/game_mode_service.dart';
import '../../services/window_service.dart';
import '../theme/colors.dart';

/// Custom styled tray menu window matching app design
class TrayMenuWindow extends StatelessWidget {
  const TrayMenuWindow({
    required this.windowService,
    required this.gameModeService,
    required this.onClose,
    required this.onOpenSettings,
    required this.onQuit,
    super.key,
  });

  final IWindowService windowService;
  final IGameModeService gameModeService;
  final VoidCallback onClose;
  final VoidCallback onOpenSettings;
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    // Windows only: macOS pops a native NSMenu from TrayService and never
    // renders this widget, so a macOS branch here could only ever be dead
    // code that looked like the place to fix macOS placement.
    // The taskbar is at the bottom, so the menu extends upward from there.
    const alignment = Alignment.bottomRight;
    const padding = EdgeInsets.only(right: 16, bottom: 60);

    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        onTap: onClose, // Close when clicking outside
        child: Container(
          color: Colors.transparent,
          child: Align(
            alignment: alignment,
            child: Padding(padding: padding, child: _buildMenu(context)),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              child: _buildMenuItem(
                icon: Icons.open_in_new,
                label: 'Open GhostCopy',
                onTap: () async {
                  onClose(); // Close tray first
                  // Wait for tray to close and state to update
                  await Future<void>.delayed(const Duration(milliseconds: 100));
                  await windowService.showSpotlight();
                },
              ),
            ),
            _buildDivider(),
            // Use StreamBuilder for reactive Game Mode toggle
            RepaintBoundary(
              child: StreamBuilder<bool>(
                stream: gameModeService.isActiveStream,
                initialData: gameModeService.isActive,
                builder: (context, snapshot) {
                  final isActive = snapshot.data ?? false;
                  return _buildMenuItem(
                    icon: Icons.videogame_asset,
                    label: 'Game Mode',
                    isChecked: isActive,
                    isToggle: true,
                    color: isActive ? GhostColors.primary : null,
                    onTap: gameModeService
                        .toggle, // Tearoff - keeps menu open so user sees toggle
                  );
                },
              ),
            ),
            _buildDivider(),
            RepaintBoundary(
              child: _buildMenuItem(
                icon: Icons.settings,
                label: 'Settings',
                onTap: () {
                  onClose(); // This will trigger opening spotlight with settings
                  onOpenSettings(); // Signal to open settings panel
                },
              ),
            ),
            _buildDivider(),
            RepaintBoundary(
              child: _buildMenuItem(
                icon: Icons.close,
                label: 'Quit',
                onTap: onQuit,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isChecked = false,
    bool isToggle = false,
    Color? color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: GhostColors.primaryAlpha10,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 14, color: color ?? Colors.white70),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color ?? Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isToggle)
                // Show toggle switch for toggle items
                Container(
                  width: 32,
                  height: 16,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: isChecked
                        ? GhostColors.primary
                        : Colors.white.withValues(alpha: 0.2),
                  ),
                  child: Align(
                    alignment: isChecked
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                  ),
                )
              else if (isChecked)
                const Icon(Icons.check, size: 14, color: GhostColors.primary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const _MenuDivider();
  }
}

/// Const divider widget for menu items
class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.white.withValues(alpha: 0.1),
    );
  }
}
