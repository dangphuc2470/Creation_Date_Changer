import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lens_template.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SettingsProvider>();

    if (!provider.isLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 24),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Defaults', style: Theme.of(context).textTheme.titleLarge),
                  const Divider(),
                  TextFormField(
                    initialValue: provider.defaultChangeDateFormat,
                    decoration: const InputDecoration(
                      labelText: 'Default Change Date Format Mask',
                      hintText: 'e.g. ****yyyyMMdd*HHmmss',
                    ),
                    onChanged: (val) {
                      context.read<SettingsProvider>().updateChangeDateFormat(val);
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    initialValue: provider.defaultRenameFormat,
                    decoration: const InputDecoration(
                      labelText: 'Default Rename Format Template',
                      hintText: 'e.g. IMG_<yyyyMMdd_HHmmss>_[nnnn]',
                    ),
                    onChanged: (val) {
                      context.read<SettingsProvider>().updateRenameFormat(val);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Geotag & Map', style: Theme.of(context).textTheme.titleLarge),
                  const Divider(),
                  ListTile(
                    title: const Text('Map Provider'),
                    subtitle: const Text('Select the default map style.'),
                    trailing: DropdownButton<String>(
                      value: provider.mapProvider,
                      items: const [
                        DropdownMenuItem(value: 'google_roadmap', child: Text('Google Maps')),
                        DropdownMenuItem(value: 'google_satellite', child: Text('Google Satellite')),
                        DropdownMenuItem(value: 'bing_roadmap', child: Text('Bing Maps')),
                        DropdownMenuItem(value: 'bing_satellite', child: Text('Bing Satellite')),
                        DropdownMenuItem(value: 'osm', child: Text('OpenStreetMap')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          context.read<SettingsProvider>().updateMapProvider(val);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Manual Lens Templates', style: Theme.of(context).textTheme.titleLarge),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () => _showAddLensDialog(context),
                      ),
                    ],
                  ),
                  const Divider(),
                  if (provider.lensTemplates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No custom lenses added.'),
                    ),
                  ...provider.lensTemplates.map((lens) {
                    return ListTile(
                      title: Text(lens.name),
                      subtitle: Text('${lens.focalLength}mm f/${lens.fNumber} - ${lens.make}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => provider.removeLensTemplate(lens.id),
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddLensDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final makeCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final focalLengthCtrl = TextEditingController();
    final fNumberCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add Manual Lens'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Display Name (e.g. Carl Zeiss)')),
                TextField(controller: makeCtrl, decoration: const InputDecoration(labelText: 'Lens Make (e.g. Carl Zeiss Jena)')),
                TextField(controller: modelCtrl, decoration: const InputDecoration(labelText: 'Lens Model (e.g. 135mm f/3.5)')),
                TextField(controller: focalLengthCtrl, decoration: const InputDecoration(labelText: 'Focal Length (mm)'), keyboardType: TextInputType.number),
                TextField(controller: fNumberCtrl, decoration: const InputDecoration(labelText: 'F-Number (Aperture)'), keyboardType: TextInputType.number),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final fl = double.tryParse(focalLengthCtrl.text) ?? 0.0;
                final fn = double.tryParse(fNumberCtrl.text) ?? 0.0;
                
                final template = LensTemplate(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text,
                  make: makeCtrl.text,
                  model: modelCtrl.text,
                  focalLength: fl,
                  fNumber: fn,
                );
                context.read<SettingsProvider>().addLensTemplate(template);
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }
}

