import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class TimezoneInfo {
  final double offset;
  final String label;
  final String city;

  const TimezoneInfo(this.offset, this.label, this.city);
}

class SettingsScreen extends StatefulWidget {
  final VoidCallback onSettingsChanged;

  const SettingsScreen({super.key, required this.onSettingsChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _timezoneOffset = 0.0;

  static const List<TimezoneInfo> _timezones = [
    TimezoneInfo(-12.0, 'UTC-12:00', 'International Date Line West'),
    TimezoneInfo(-11.0, 'UTC-11:00', 'Samoa / Midway'),
    TimezoneInfo(-10.0, 'UTC-10:00', 'Honolulu / Papeete'),
    TimezoneInfo(-9.0, 'UTC-09:00', 'Anchorage'),
    TimezoneInfo(-8.0, 'UTC-08:00', 'Los Angeles / Vancouver'),
    TimezoneInfo(-7.0, 'UTC-07:00', 'Denver / Phoenix'),
    TimezoneInfo(-6.0, 'UTC-06:00', 'Chicago / Mexico City'),
    TimezoneInfo(-5.0, 'UTC-05:00', 'New York / Toronto / Lima'),
    TimezoneInfo(-4.0, 'UTC-04:00', 'Santiago / Halifax'),
    TimezoneInfo(-3.5, 'UTC-03:30', 'St. John\'s'),
    TimezoneInfo(-3.0, 'UTC-03:00', 'Buenos Aires / Sao Paulo'),
    TimezoneInfo(-2.0, 'UTC-02:00', 'South Georgia'),
    TimezoneInfo(-1.0, 'UTC-01:00', 'Azores'),
    TimezoneInfo(0.0, 'UTC+00:00', 'London / Lisbon / Casablanca'),
    TimezoneInfo(1.0, 'UTC+01:00', 'Berlin / Paris / Rome / Madrid'),
    TimezoneInfo(2.0, 'UTC+02:00', 'Cairo / Jerusalem / Johannesburg'),
    TimezoneInfo(3.0, 'UTC+03:00', 'Moscow / Riyadh / Nairobi'),
    TimezoneInfo(3.5, 'UTC+03:30', 'Tehran'),
    TimezoneInfo(4.0, 'UTC+04:00', 'Dubai / Baku / Tbilisi'),
    TimezoneInfo(4.5, 'UTC+04:30', 'Kabul'),
    TimezoneInfo(5.0, 'UTC+05:00', 'Karachi / Tashkent'),
    TimezoneInfo(5.5, 'UTC+05:30', 'Mumbai / Delhi / Colombo'),
    TimezoneInfo(5.75, 'UTC+05:45', 'Kathmandu'),
    TimezoneInfo(6.0, 'UTC+06:00', 'Dhaka / Almaty'),
    TimezoneInfo(6.5, 'UTC+06:30', 'Yangon'),
    TimezoneInfo(7.0, 'UTC+07:00', 'Bangkok / Jakarta / Hanoi'),
    TimezoneInfo(8.0, 'UTC+08:00', 'Beijing / Perth / Singapore / Manila'),
    TimezoneInfo(8.75, 'UTC+08:45', 'Eucla'),
    TimezoneInfo(9.0, 'UTC+09:00', 'Tokyo / Seoul'),
    TimezoneInfo(9.5, 'UTC+09:30', 'Adelaide / Darwin'),
    TimezoneInfo(10.0, 'UTC+10:00', 'Sydney / Brisbane / Guam'),
    TimezoneInfo(10.5, 'UTC+10:30', 'Lord Howe Island'),
    TimezoneInfo(11.0, 'UTC+11:00', 'Solomon Is. / Noumea'),
    TimezoneInfo(12.0, 'UTC+12:00', 'Auckland / Suva'),
    TimezoneInfo(12.75, 'UTC+12:45', 'Chatham Islands'),
    TimezoneInfo(13.0, 'UTC+13:00', 'Nuku\'alofa'),
    TimezoneInfo(14.0, 'UTC+14:00', 'Kiritimati'),
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final offset = await SettingsService.getTimezoneOffset();
    setState(() {
      _timezoneOffset = offset;
    });
  }

  void _updateOffset(double? value) {
    if (value == null) return;
    setState(() {
      _timezoneOffset = value;
    });
    SettingsService.setTimezoneOffset(value);
    widget.onSettingsChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Settings',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 32),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Timezone Settings',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Select your timezone to adjust the display time for location points.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[600],
                          ),
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        const Icon(Icons.public, color: Colors.blue),
                        const SizedBox(width: 16),
                        const Text(
                          'Select Timezone:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: DropdownButtonFormField<double>(
                            value: _timezones
                                    .any((tz) => tz.offset == _timezoneOffset)
                                ? _timezoneOffset
                                : 0.0,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                            ),
                            items: _timezones.map((tz) {
                              return DropdownMenuItem<double>(
                                value: tz.offset,
                                child: Text('${tz.label} - ${tz.city}'),
                              );
                            }).toList(),
                            onChanged: _updateOffset,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
