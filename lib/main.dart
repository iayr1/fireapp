import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'firebase_options.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Advanced Visitor Analytics',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.light,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          color: Colors.white,
          shadowColor: Colors.black.withOpacity(0.1),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        fontFamily: 'SF Pro Display',
      ),
      debugShowCheckedModeBanner: false,
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late MapController _mapController;
  late AnimationController _refreshController;
  Map<String, dynamic> _dashboardData = {};
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _mapController = MapController();
    _refreshController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
    _fetchData();
  }

  // Enhanced IP geolocation with multiple fallbacks
  Future<Map<String, dynamic>> _getEnhancedLocationData(String ip) async {
    final List<String> apiEndpoints = [
      'https://ipapi.co/$ip/json/',
      'https://api.ipgeolocation.io/ipgeo?apiKey=YOUR_API_KEY&ip=$ip',
      'https://ipinfo.io/$ip/json',
    ];

    for (String endpoint in apiEndpoints) {
      try {
        final res = await http.get(Uri.parse(endpoint.replaceAll('$ip', ip)));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          return {
            'city': data['city'] ?? data['city_name'] ?? '',
            'region': data['region'] ?? data['state_prov'] ?? data['region_name'] ?? '',
            'country': data['country_name'] ?? data['country'] ?? '',
            'countryCode': data['country_code'] ?? data['country_code2'] ?? '',
            'latitude': (data['latitude'] ?? data['lat'])?.toDouble(),
            'longitude': (data['longitude'] ?? data['lon'])?.toDouble(),
            'isp': data['org'] ?? data['isp'] ?? '',
            'timezone': data['timezone'] ?? '',
            'postal': data['postal'] ?? data['zipcode'] ?? '',
            'asn': data['asn'] ?? '',
            'proxy': data['proxy'] ?? false,
            'hosting': data['hosting'] ?? false,
          };
        }
      } catch (e) {
        debugPrint("API Error for $endpoint: $e");
        continue;
      }
    }
    return {'city': 'Unknown', 'region': '', 'country': 'Unknown'};
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    _refreshController.forward();

    Map<String, Map<String, dynamic>> grouped = {};
    List<Marker> markers = [];
    Map<String, int> countryStats = {};
    Map<String, int> deviceStats = {};
    Map<String, int> browserStats = {};

    // Fetch all collections in parallel
    final futures = await Future.wait([
      FirebaseFirestore.instance.collection('contact_messages').get(),
      FirebaseFirestore.instance.collection('project_views').get(),
      FirebaseFirestore.instance.collection('visitor_analytics').get(),
    ]);

    // Process each collection
    for (int i = 0; i < futures.length; i++) {
      final collection = ['contact', 'project', 'visit'][i];
      for (var doc in futures[i].docs) {
        var data = doc.data() as Map<String, dynamic>;
        String ip = data['ipAddress'] ?? 'unknown';
        await _processVisitorData(grouped, markers, ip, collection, data, 
            countryStats, deviceStats, browserStats);
      }
    }

    // Calculate additional analytics
    final analytics = _calculateAdvancedAnalytics(grouped);

    setState(() {
      _dashboardData = {
        'profiles': grouped,
        'markers': markers,
        'countryStats': countryStats,
        'deviceStats': deviceStats,
        'browserStats': browserStats,
        ...analytics,
      };
      _isLoading = false;
    });

    _refreshController.reverse();
  }

  Map<String, dynamic> _calculateAdvancedAnalytics(Map<String, Map<String, dynamic>> grouped) {
    int totalVisitors = grouped.length;
    int totalMessages = 0;
    int totalProjectViews = 0;
    int totalVisits = 0;
    int activeVisitors = 0; // visitors in last 24 hours
    int returningVisitors = 0;
    double avgSessionDuration = 0;
    
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    
    for (var profile in grouped.values) {
      totalMessages += (profile['messages'] as List).length;
      totalProjectViews += (profile['projects'] as List).length;
      totalVisits += (profile['visits'] as List).length;
      
      if (profile['lastSeen'].isAfter(yesterday)) {
        activeVisitors++;
      }
      
      if ((profile['visits'] as List).length > 1) {
        returningVisitors++;
      }
      
      // Calculate session duration (simplified)
      final duration = profile['lastSeen'].difference(profile['firstSeen']).inMinutes;
      avgSessionDuration += duration;
    }
    
    avgSessionDuration = totalVisitors > 0 ? avgSessionDuration / totalVisitors : 0;
    
    return {
      'totalVisitors': totalVisitors,
      'totalMessages': totalMessages,
      'totalProjectViews': totalProjectViews,
      'totalVisits': totalVisits,
      'activeVisitors': activeVisitors,
      'returningVisitors': returningVisitors,
      'avgSessionDuration': avgSessionDuration,
      'conversionRate': totalVisitors > 0 ? (totalMessages / totalVisitors * 100) : 0.0,
    };
  }

  Future<void> _processVisitorData(
    Map<String, Map<String, dynamic>> grouped,
    List<Marker> markers,
    String ip,
    String type,
    Map<String, dynamic> data,
    Map<String, int> countryStats,
    Map<String, int> deviceStats,
    Map<String, int> browserStats,
  ) async {
    grouped[ip] ??= {
      'ip': ip,
      'projects': [],
      'messages': [],
      'visits': [],
      'location': 'Loading...',
      'coordinates': null,
      'firstSeen': DateTime.now(),
      'lastSeen': DateTime.now(),
      'visitCount': 0,
      'sessionDuration': 0,
      'deviceInfo': {},
      'referrers': <String>[],
      'userAgents': <String>[],
      'riskScore': 0, // 0-100 risk assessment
      'isReturning': false,
      'locationData': {},
    };

    // Update timestamps
    final timestamp = data['timestamp']?.toDate() ?? DateTime.now();
    if (timestamp.isBefore(grouped[ip]!['firstSeen'])) {
      grouped[ip]!['firstSeen'] = timestamp;
    }
    if (timestamp.isAfter(grouped[ip]!['lastSeen'])) {
      grouped[ip]!['lastSeen'] = timestamp;
    }

    // Track user agents and referrers
    final userAgent = data['userAgent'] ?? '';
    if (userAgent.isNotEmpty && !(grouped[ip]!['userAgents'] as List).contains(userAgent)) {
      (grouped[ip]!['userAgents'] as List<String>).add(userAgent);
    }

    // Extract device and browser info from user agent
    if (data['deviceInfo'] != null) {
      grouped[ip]!['deviceInfo'] = data['deviceInfo'];
      final deviceType = data['deviceInfo']['device'] ?? 'unknown';
      final browser = data['deviceInfo']['browser'] ?? 'unknown';
      deviceStats[deviceType] = (deviceStats[deviceType] ?? 0) + 1;
      browserStats[browser] = (browserStats[browser] ?? 0) + 1;
    }

    // Track referrers
    if (data['referrer'] != null) {
      final referrer = data['referrer'] as String;
      if (!(grouped[ip]!['referrers'] as List).contains(referrer)) {
        (grouped[ip]!['referrers'] as List<String>).add(referrer);
      }
    }

    // Add data based on type with enhanced tracking
    final enhancedData = {
      ...data,
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'sessionId': data['sessionId'] ?? 'session_${DateTime.now().millisecondsSinceEpoch}',
    };

    switch (type) {
      case 'contact':
        grouped[ip]!['messages'].add({
          ...enhancedData,
          'subject': data['subject'],
          'message': data['message'],
          'email': data['email'],
          'firstName': data['firstName'],
          'lastName': data['lastName'],
          'status': data['status'] ?? 'new',
        });
        break;
      case 'project':
        grouped[ip]!['projects'].add({
          ...enhancedData,
          'projectName': data['projectName'],
        });
        break;
      case 'visit':
        grouped[ip]!['visits'].add({
          ...enhancedData,
          'hasReferrer': data['hasReferrer'] ?? false,
          'isFirstVisit': data['isFirstVisit'] ?? true,
          'referrerDomain': data['referrerDomain'] ?? '',
          'visitDay': data['visitDay'],
          'visitHour': data['visitHour'],
          'visitMonth': data['visitMonth'],
          'visitYear': data['visitYear'],
        });
        
        // Update visit count
        grouped[ip]!['visitCount'] = (grouped[ip]!['visits'] as List).length;
        grouped[ip]!['isReturning'] = !(data['isFirstVisit'] ?? true);
        break;
    }

    // Get enhanced location data if not already fetched
    if (grouped[ip]!['location'] == 'Loading...' || grouped[ip]!['coordinates'] == null) {
      final locationData = await _getEnhancedLocationData(ip);
      grouped[ip]!['locationData'] = locationData;
      
      final city = locationData['city'] ?? '';
      final region = locationData['region'] ?? '';
      final country = locationData['country'] ?? '';
      
      grouped[ip]!['location'] = '$city${region.isNotEmpty ? ", $region" : ""}${country.isNotEmpty ? ", $country" : ""}';
      
      // Update country stats
      if (country.isNotEmpty) {
        countryStats[country] = (countryStats[country] ?? 0) + 1;
      }

      final lat = locationData['latitude'];
      final lng = locationData['longitude'];
      if (lat != null && lng != null) {
        final coords = LatLng(lat, lng);
        grouped[ip]!['coordinates'] = coords;

        // Calculate risk score based on various factors
        int riskScore = 0;
        if (locationData['proxy'] == true) riskScore += 30;
        if (locationData['hosting'] == true) riskScore += 20;
        if ((grouped[ip]!['userAgents'] as List).length > 3) riskScore += 15;
        if ((grouped[ip]!['visits'] as List).length > 50) riskScore += 10;
        grouped[ip]!['riskScore'] = riskScore;

        final interactions = (grouped[ip]!['messages'] as List).length +
            (grouped[ip]!['projects'] as List).length +
            (grouped[ip]!['visits'] as List).length;

        markers.add(
          Marker(
            point: coords,
            width: 50,
            height: 50,
            child: GestureDetector(
              onTap: () => _showEnhancedMarkerDialog(ip, grouped[ip]!),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _getMarkerGradient(grouped[ip]!),
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Text(
                        interactions.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (grouped[ip]!['riskScore'] > 50)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            FontAwesomeIcons.exclamation,
                            color: Colors.white,
                            size: 8,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ).animate().scale(duration: 600.ms).then().shimmer(),
          ),
        );
      }
    }
  }

  void _showEnhancedMarkerDialog(String ip, Map<String, dynamic> profile) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [Colors.white, Colors.grey.shade50],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: _getMarkerGradient(profile)[0],
                    child: Text(
                      ip.split('.').last,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Visitor $ip',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          profile['location'] ?? 'Unknown Location',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  if (profile['riskScore'] > 50)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Risk: ${profile['riskScore']}%',
                        style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildDialogStat('Messages', profile['messages'].length.toString(), FontAwesomeIcons.envelope),
                  _buildDialogStat('Projects', profile['projects'].length.toString(), FontAwesomeIcons.eye),
                  _buildDialogStat('Visits', profile['visits'].length.toString(), FontAwesomeIcons.mouse),
                  _buildDialogStat('Sessions', profile['visitCount'].toString(), FontAwesomeIcons.clock),
                ],
              ),
              const SizedBox(height: 16),
              if (profile['locationData'] != null) ...[
                _buildLocationDetails(profile['locationData']),
                const SizedBox(height: 16),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _showDetailedProfile(ip, profile);
                    },
                    child: const Text('View Details'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDialogStat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF6366F1)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  Widget _buildLocationDetails(Map<String, dynamic> locationData) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(FontAwesomeIcons.globe, size: 16, color: Colors.blue),
              const SizedBox(width: 8),
              Text('ISP: ${locationData['isp'] ?? 'Unknown'}', style: const TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(FontAwesomeIcons.clock, size: 16, color: Colors.blue),
              const SizedBox(width: 8),
              Text('Timezone: ${locationData['timezone'] ?? 'Unknown'}', style: const TextStyle(fontSize: 12)),
            ],
          ),
          if (locationData['proxy'] == true || locationData['hosting'] == true) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (locationData['proxy'] == true)
                  _buildWarningChip('Proxy Detected'),
                if (locationData['hosting'] == true)
                  _buildWarningChip('Hosting Provider'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWarningChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  void _showDetailedProfile(String ip, Map<String, dynamic> profile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DetailedProfilePage(ip: ip, profile: profile),
      ),
    );
  }

  List<Color> _getMarkerGradient(Map<String, dynamic> profile) {
    final interactions = (profile['messages'] as List).length +
        (profile['projects'] as List).length +
        (profile['visits'] as List).length;
    
    if (profile['riskScore'] > 50) {
      return [Colors.red.shade400, Colors.red.shade600];
    } else if (interactions >= 20) {
      return [Colors.purple.shade400, Colors.purple.shade600];
    } else if (interactions >= 10) {
      return [Colors.orange.shade400, Colors.orange.shade600];
    } else if (interactions >= 5) {
      return [Colors.blue.shade400, Colors.blue.shade600];
    }
    return [Colors.green.shade400, Colors.green.shade600];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF667EEA),
              Color(0xFF764BA2),
              Color(0xFF6366F1),
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildEnhancedHeader(),
              _buildEnhancedTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildOverviewTab(),
                    _buildAnalyticsTab(),
                    _buildMapTab(),
                    _buildRealTimeTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _fetchData,
        icon: AnimatedBuilder(
          animation: _refreshController,
          builder: (context, child) {
            return Transform.rotate(
              angle: _refreshController.value * 6.28,
              child: const Icon(FontAwesomeIcons.arrowsRotate),
            );
          },
        ),
        label: const Text('Refresh'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF6366F1),
      ),
    );
  }

  Widget _buildEnhancedHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              FontAwesomeIcons.chartLine,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Advanced Analytics',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Real-time visitor insights',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ).animate(onPlay: (controller) => controller.repeat())
                  .shimmer(duration: 2000.ms),
                const SizedBox(width: 8),
                const Text(
                  'Live',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        labelColor: const Color(0xFF6366F1),
        unselectedLabelColor: Colors.white,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold),
        tabs: const [
          Tab(text: 'Overview'),
          Tab(text: 'Analytics'),
          Tab(text: 'Map'),
          Tab(text: 'Live'),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    if (_isLoading) {
      return Container(
        margin: const EdgeInsets.only(top: 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(30),
            topRight: Radius.circular(30),
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator.adaptive(),
              const SizedBox(height: 24),
              Text(
                'Loading visitor data...',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final profiles = _dashboardData['profiles'] ?? {};
    final filteredProfiles = _filterProfiles(profiles);

    return Container(
      margin: const EdgeInsets.only(top: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(30),
          topRight: Radius.circular(30),
        ),
      ),
      child: Column(
        children: [
          _buildSearchBar(),
          _buildEnhancedStatsCards(),
          Expanded(child: _buildEnhancedVisitorList(filteredProfiles)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: TextField(
        onChanged: (value) => setState(() => _searchQuery = value),
        decoration: const InputDecoration(
          hintText: 'Search by IP, location, or activity...',
          prefixIcon: Icon(FontAwesomeIcons.magnifyingGlass),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Map<String, dynamic> _filterProfiles(Map<String, dynamic> profiles) {
    if (_searchQuery.isEmpty) return profiles;
    
    return Map.fromEntries(
      profiles.entries.where((entry) {
        final profile = entry.value;
        final searchLower = _searchQuery.toLowerCase();
        
        return profile['ip'].toString().contains(searchLower) ||
               profile['location'].toString().toLowerCase().contains(searchLower) ||
               profile['messages'].any((m) => 
                 m['subject'].toString().toLowerCase().contains(searchLower)) ||
               profile['projects'].any((p) => 
                 p['projectName'].toString().toLowerCase().contains(searchLower));
      }),
    );
  }

  Widget _buildEnhancedStatsCards() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildEnhancedStatCard(
                'Total Visitors',
                _dashboardData['totalVisitors']?.toString() ?? '0',
                FontAwesomeIcons.users,
                [Colors.blue.shade400, Colors.blue.shade600],
                'Active: ${_dashboardData['activeVisitors'] ?? 0}',
              )),
              const SizedBox(width: 12),
              Expanded(child: _buildEnhancedStatCard(
                'Messages',
                _dashboardData['totalMessages']?.toString() ?? '0',
                FontAwesomeIcons.envelope,
                [Colors.green.shade400, Colors.green.shade600],
                'Conversion: ${(_dashboardData['conversionRate'] ?? 0).toStringAsFixed(1)}%',
              )),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildEnhancedStatCard(
                'Page Views',
                _dashboardData['totalProjectViews']?.toString() ?? '0',
                FontAwesomeIcons.eye,
                [Colors.orange.shade400, Colors.orange.shade600],
                'Avg session: ${(_dashboardData['avgSessionDuration'] ?? 0).toStringAsFixed(0)}m',
              )),
              const SizedBox(width: 12),
              Expanded(child: _buildEnhancedStatCard(
                'Returning',
                _dashboardData['returningVisitors']?.toString() ?? '0',
                FontAwesomeIcons.arrowRotateLeft,
                [Colors.purple.shade400, Colors.purple.shade600],
                '${_dashboardData['totalVisitors'] > 0 ? ((_dashboardData['returningVisitors'] ?? 0) / _dashboardData['totalVisitors'] * 100).toStringAsFixed(1) : 0}%',
              )),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedStatCard(String title, String value, IconData icon, 
      List<Color> gradient, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: gradient[0].withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.3);
  }

  Widget _buildEnhancedVisitorList(Map<String, dynamic> profiles) {
    if (profiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(FontAwesomeIcons.userSlash, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty ? 'No visitors yet' : 'No matching visitors found',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
            ),
          ],
        ),
      );
    }

    final sortedEntries = profiles.entries.toList()
      ..sort((a, b) => (b.value['lastSeen'] as DateTime)
          .compareTo(a.value['lastSeen'] as DateTime));

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: sortedEntries.length,
      itemBuilder: (context, index) {
        final entry = sortedEntries[index];
        return _buildEnhancedVisitorCard(entry.key, entry.value, index);
      },
    );
  }

  Widget _buildEnhancedVisitorCard(String ip, Map<String, dynamic> profile, int index) {
    final totalInteractions = (profile['messages'] as List).length +
        (profile['projects'] as List).length +
        (profile['visits'] as List).length;

    final riskScore = profile['riskScore'] ?? 0;
    final isHighRisk = riskScore > 50;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [Colors.white, Colors.grey.shade50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: isHighRisk ? Colors.red.withOpacity(0.1) : Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
        border: isHighRisk ? Border.all(color: Colors.red.shade300, width: 1) : null,
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.all(20),
        childrenPadding: const EdgeInsets.all(20),
        leading: Stack(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _getMarkerGradient(profile),
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: _getMarkerGradient(profile)[0].withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  ip.split('.').last,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            if (isHighRisk)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    FontAwesomeIcons.exclamation,
                    color: Colors.white,
                    size: 10,
                  ),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ip,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(FontAwesomeIcons.locationDot, size: 12, color: Colors.grey.shade600),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          profile['location'] ?? 'Unknown',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isHighRisk)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Risk: $riskScore%',
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  _formatDateTime(profile['lastSeen']),
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
        subtitle: Container(
          margin: const EdgeInsets.only(top: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _buildEnhancedChip('$totalInteractions interactions', Colors.blue),
              if (profile['isReturning'] == true)
                _buildEnhancedChip('Returning', Colors.green),
              if (profile['visitCount'] > 10)
                _buildEnhancedChip('Frequent', Colors.orange),
              if (profile['coordinates'] != null)
                _buildEnhancedChip('Located', Colors.purple),
            ],
          ),
        ),
        children: [
          _buildDetailedProfileView(profile),
        ],
      ),
    ).animate(delay: (index * 50).ms).fadeIn().slideX(begin: -0.2);
  }

  Widget _buildDetailedProfileView(Map<String, dynamic> profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Quick Stats Row
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildQuickStat('Messages', profile['messages'].length.toString(), FontAwesomeIcons.envelope),
              _buildQuickStat('Projects', profile['projects'].length.toString(), FontAwesomeIcons.eye),
              _buildQuickStat('Visits', profile['visits'].length.toString(), FontAwesomeIcons.mouse),
              _buildQuickStat('Sessions', profile['visitCount'].toString(), FontAwesomeIcons.clock),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Messages Section
        if ((profile['messages'] as List).isNotEmpty) ...[
          _buildEnhancedSectionHeader('Contact Messages', FontAwesomeIcons.envelope, Colors.green),
          ...(profile['messages'] as List).take(3).map<Widget>((m) => _buildEnhancedDetailItem(
            m['subject'] ?? 'No subject',
            '${m['firstName'] ?? ''} ${m['lastName'] ?? ''}'.trim(),
            m['email'] ?? '',
            m['timestamp']?.toDate(),
            FontAwesomeIcons.envelope,
          )),
          if ((profile['messages'] as List).length > 3)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                '+ ${(profile['messages'] as List).length - 3} more messages',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
        ],

        // Projects Section
        if ((profile['projects'] as List).isNotEmpty) ...[
          _buildEnhancedSectionHeader('Project Views', FontAwesomeIcons.eye, Colors.blue),
          ...(profile['projects'] as List).take(3).map<Widget>((p) => _buildEnhancedDetailItem(
            p['projectName'] ?? 'Unknown project',
            _extractBrowserFromUserAgent(p['userAgent'] ?? ''),
            _formatDateTime(p['timestamp']?.toDate()),
            p['timestamp']?.toDate(),
            FontAwesomeIcons.eye,
          )),
          if ((profile['projects'] as List).length > 3)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text(
                '+ ${(profile['projects'] as List).length - 3} more views',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
        ],

        // Device & Location Info
        _buildDeviceLocationInfo(profile),
      ],
    );
  }

  Widget _buildQuickStat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF6366F1)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildEnhancedSectionHeader(String title, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedDetailItem(String title, String subtitle, String extra, 
      DateTime? timestamp, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 14, color: const Color(0xFF6366F1)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
                if (extra.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    extra,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (timestamp != null)
            Text(
              _getTimeAgo(timestamp),
              style: TextStyle(color: Colors.grey.shade400, fontSize: 10),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceLocationInfo(Map<String, dynamic> profile) {
    final deviceInfo = profile['deviceInfo'] ?? {};
    final locationData = profile['locationData'] ?? {};
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue.shade50, Colors.indigo.shade50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Technical Details',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (deviceInfo['device'] != null)
                _buildInfoTag('Device', deviceInfo['device'], FontAwesomeIcons.mobileScreenButton),
              if (deviceInfo['browser'] != null)
                _buildInfoTag('Browser', deviceInfo['browser'], FontAwesomeIcons.globe),
              if (deviceInfo['os'] != null)
                _buildInfoTag('OS', deviceInfo['os'], FontAwesomeIcons.desktop),
              if (locationData['isp'] != null)
                _buildInfoTag('ISP', locationData['isp'], FontAwesomeIcons.wifi),
              if (locationData['timezone'] != null)
                _buildInfoTag('Timezone', locationData['timezone'], FontAwesomeIcons.clock),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTag(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildAnalyticsTab() {
    if (_isLoading) {
      return Container(
        margin: const EdgeInsets.only(top: 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(30),
            topRight: Radius.circular(30),
          ),
        ),
        child: const Center(
          child: CircularProgressIndicator.adaptive(),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(30),
          topRight: Radius.circular(30),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAnalyticsSection('Geographic Distribution', _buildCountryChart()),
            const SizedBox(height: 24),
            _buildAnalyticsSection('Device Types', _buildDeviceChart()),
            const SizedBox(height: 24),
            _buildAnalyticsSection('Browser Usage', _buildBrowserChart()),
            const SizedBox(height: 24),
            _buildAnalyticsSection('Activity Timeline', _buildTimelineChart()),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticsSection(String title, Widget chart) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF6366F1),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: chart,
        ),
      ],
    );
  }

  Widget _buildCountryChart() {
    final countryStats = _dashboardData['countryStats'] as Map<String, int>? ?? {};
    if (countryStats.isEmpty) {
      return const Center(
        child: Text('No geographic data available'),
      );
    }

    return Column(
      children: countryStats.entries.take(5).map((entry) {
        final percentage = (entry.value / countryStats.values.reduce((a, b) => a + b)) * 100;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w500)),
                  Text('${entry.value} (${percentage.toStringAsFixed(1)}%)'),
                ],
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: percentage / 100,
                backgroundColor: Colors.grey.shade300,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Colors.primaries[countryStats.keys.toList().indexOf(entry.key) % Colors.primaries.length],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDeviceChart() {
    final deviceStats = _dashboardData['deviceStats'] as Map<String, int>? ?? {};
    if (deviceStats.isEmpty) {
      return const Center(
        child: Text('No device data available'),
      );
    }

    return Column(
      children: deviceStats.entries.map((entry) {
        final percentage = (entry.value / deviceStats.values.reduce((a, b) => a + b)) * 100;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(
                entry.key.toLowerCase() == 'mobile' ? FontAwesomeIcons.mobileScreenButton :
                entry.key.toLowerCase() == 'tablet' ? FontAwesomeIcons.tablet :
                FontAwesomeIcons.desktop,
                size: 16,
                color: const Color(0xFF6366F1),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w500)),
                        Text('${entry.value} (${percentage.toStringAsFixed(1)}%)'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: percentage / 100,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBrowserChart() {
    final browserStats = _dashboardData['browserStats'] as Map<String, int>? ?? {};
    if (browserStats.isEmpty) {
      return const Center(
        child: Text('No browser data available'),
      );
    }

    return Column(
      children: browserStats.entries.take(5).map((entry) {
        final percentage = (entry.value / browserStats.values.reduce((a, b) => a + b)) * 100;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(
                entry.key.toLowerCase().contains('chrome') ? FontAwesomeIcons.chrome :
                entry.key.toLowerCase().contains('firefox') ? FontAwesomeIcons.firefox :
                entry.key.toLowerCase().contains('safari') ? FontAwesomeIcons.safari :
                entry.key.toLowerCase().contains('edge') ? FontAwesomeIcons.edge :
                FontAwesomeIcons.globe,
                size: 16,
                color: _getBrowserColor(entry.key),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w500)),
                        Text('${entry.value} (${percentage.toStringAsFixed(1)}%)'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: percentage / 100,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation<Color>(_getBrowserColor(entry.key)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTimelineChart() {
    final profiles = _dashboardData['profiles'] as Map<String, dynamic>? ?? {};
    if (profiles.isEmpty) {
      return const Center(
        child: Text('No timeline data available'),
      );
    }

    // Group visits by hour of day
    Map<int, int> hourlyVisits = {};
    for (var profile in profiles.values) {
      for (var visit in profile['visits']) {
        final timestamp = visit['timestamp']?.toDate() ?? DateTime.now();
        final hour = timestamp.hour;
        hourlyVisits[hour] = (hourlyVisits[hour] ?? 0) + 1;
      }
    }

    return Container(
      height: 200,
      child: Column(
        children: [
          const Text('Visits by Hour of Day', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(24, (index) {
                final visits = hourlyVisits[index] ?? 0;
                final maxVisits = hourlyVisits.values.isNotEmpty ? 
                    hourlyVisits.values.reduce((a, b) => a > b ? a : b) : 1;
                final height = visits == 0 ? 4.0 : (visits / maxVisits) * 140 + 4;
                
                return Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      width: 8,
                      height: height,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      index.toString().padLeft(2, '0'),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapTab() {
    final markers = _dashboardData['markers'] as List<Marker>? ?? [];

    return Container(
      margin: const EdgeInsets.only(top: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(30),
          topRight: Radius.circular(30),
        ),
      ),
      child: markers.isEmpty ? 
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(FontAwesomeIcons.mapLocationDot, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                'No location data available',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                'Visitor locations will appear here once geolocation data is available',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ) :
        ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(30),
            topRight: Radius.circular(30),
          ),
          child: FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: LatLng(20.0, 0.0),
              initialZoom: 2.0,
              minZoom: 1.0,
              maxZoom: 18.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.visitoranalytics.app',
                maxZoom: 18,
              ),
              MarkerLayer(markers: markers),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
        ),
    );
  }

  Widget _buildRealTimeTab() {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(30),
          topRight: Radius.circular(30),
        ),
      ),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('visitor_analytics')
            .orderBy('timestamp', descending: true)
            .limit(20)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }

          final recentVisits = snapshot.data?.docs ?? [];
          
          return Column(
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ).animate(onPlay: (controller) => controller.repeat())
                      .shimmer(duration: 2000.ms),
                    const SizedBox(width: 12),
                    const Text(
                      'Live Activity Feed',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: recentVisits.isEmpty ?
                  const Center(
                    child: Text('No recent activity'),
                  ) :
                  ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: recentVisits.length,
                    itemBuilder: (context, index) {
                      final data = recentVisits[index].data() as Map<String, dynamic>;
                      return _buildRealTimeItem(data, index);
                    },
                  ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRealTimeItem(Map<String, dynamic> data, int index) {
    final timestamp = data['timestamp']?.toDate() ?? DateTime.now();
    final ip = data['ipAddress'] ?? 'Unknown';
    final location = data['geolocation'] != null ?
        '${data['geolocation']['city'] ?? ''}, ${data['geolocation']['country'] ?? ''}' :
        'Unknown Location';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              FontAwesomeIcons.user,
              color: Color(0xFF6366F1),
              size: 16,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'New visit from $ip',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  location,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                Text(
                  _getTimeAgo(timestamp),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                ),
              ],
            ),
          ),
          if (data['deviceInfo'] != null)
            Icon(
              data['deviceInfo']['device'] == 'mobile' ? 
                FontAwesomeIcons.mobileScreenButton : FontAwesomeIcons.desktop,
              size: 14,
              color: Colors.grey.shade500,
            ),
        ],
      ),
    ).animate(delay: (index * 100).ms).fadeIn().slideX(begin: 0.3);
  }

  Color _getBrowserColor(String browser) {
    switch (browser.toLowerCase()) {
      case 'chrome': return const Color(0xFF4285F4);
      case 'firefox': return const Color(0xFFFF7139);
      case 'safari': return const Color(0xFF1B88CA);
      case 'edge': return const Color(0xFF0078D4);
      default: return const Color(0xFF6366F1);
    }
  }

  String _extractBrowserFromUserAgent(String userAgent) {
    if (userAgent.contains('Chrome')) return 'Chrome';
    if (userAgent.contains('Firefox')) return 'Firefox';
    if (userAgent.contains('Safari')) return 'Safari';
    if (userAgent.contains('Edge')) return 'Edge';
    return 'Unknown';
  }

  String _getTimeAgo(DateTime dateTime) {
    final difference = DateTime.now().difference(dateTime);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return DateFormat('MMM dd, yyyy HH:mm').format(dateTime);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _refreshController.dispose();
    super.dispose();
  }
}

// Detailed Profile Page (optional enhancement)
class DetailedProfilePage extends StatelessWidget {
  final String ip;
  final Map<String, dynamic> profile;

  const DetailedProfilePage({
    super.key,
    required this.ip,
    required this.profile,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Visitor $ip'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Profile header with enhanced details
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [const Color(0xFF6366F1), const Color(0xFF8B5CF6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ip,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    profile['location'] ?? 'Unknown Location',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _buildProfileStat('Risk Score', '${profile['riskScore'] ?? 0}%'),
                      const SizedBox(width: 20),
                      _buildProfileStat('Visit Count', '${profile['visitCount'] ?? 0}'),
                      const SizedBox(width: 20),
                      _buildProfileStat('Total Activities', 
                          '${(profile['messages'] as List).length + (profile['projects'] as List).length + (profile['visits'] as List).length}'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Add more detailed sections here...
          ],
        ),
      ),
    );
  }

  Widget _buildProfileStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
