import 'package:flutter/material.dart';
import 'cloud_gallery_tab.dart';
import 'local_gallery_tab.dart';

/// Galería unificada: pestaña Local (fotos del teléfono pendientes de subir)
/// y pestaña Cloud (lo que ya está en la nube).
class GalleryScreen extends StatelessWidget {
  final int initialTab;
  const GalleryScreen({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Galería'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.phone_android), text: 'Local'),
              Tab(icon: Icon(Icons.cloud_outlined), text: 'Cloud'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            LocalGalleryTab(),
            CloudGalleryTab(),
          ],
        ),
      ),
    );
  }
}
