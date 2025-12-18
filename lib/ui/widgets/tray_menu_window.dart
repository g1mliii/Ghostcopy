import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../../services/game_mode_service.dart';
import '../../services/window_service.dart';

/// Custom styled tray menu window matching app design
class TrayMenuWindow extends StatelessWidget {
  const TrayMenuWindow({
    required this.windowService,
    required this.gameModeService,
    required this.onClose,
    super.key,
  });

  final IWindowService windowService;
  final IGameModeService gameModeService;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: onClose, // Close when clicking outside
        child: Container(
          color: Colors.transparent,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _buildMenu(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1D), // Dark surface from theme
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildMenuItem(
            icon: Icons.visibility,
            label: 'Show Spotlight',
            onTap: () {
              windowService.showSpotlight();
              onClose();
            },
          ),
          _buildDivider(),
          _buildMenuItem(
            icon: Icons.videogame_asset,
            label: 'Game Mode',
            isChecked: gameModeService.isActive,
            onTap: () {
              gameModeService.toggle();
              onClose();
            },
          ),
          _buildDivider(),
          _buildMenuItem(
            icon: Icons.settings,
            label: 'Settings',
            onTap: () {
              debugPrint('Settings clicked');
              onClose();
            },
          ),
          _buildDivider(),
          _buildMenuItem(
            icon: Icons.close,
            label: 'Quit',
            onTap: windowManager.destroy,
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isChecked = false,
    Color? color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: const Color(0xFF5865F2).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: color ?? Colors.white70,
              ),
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
              if (isChecked)
                const Icon(
                  Icons.check,
                  size: 14,
                  color: Color(0xFF5865F2), // Primary accent
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.white.withValues(alpha: 0.1),
    );
  }
}
