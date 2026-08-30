import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

typedef OjpHttpPost =
    Future<http.Response> Function(
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
    });

class OjpStopEventRecord {
  const OjpStopEventRecord({
    required this.journeyRef,
    required this.operatingDayRef,
    required this.destinationText,
    this.hasPreviousServicedCall = false,
    this.stopPointRef = '',
    this.stopPointName = '',
    this.publicLineName = '',
    this.transportMode = '',
    this.scheduledArrival,
    this.estimatedArrival,
    this.isDestinationServiced = true,
  });

  final String journeyRef;
  final String operatingDayRef;
  final String destinationText;
  final bool hasPreviousServicedCall;
  final String stopPointRef;
  final String stopPointName;
  final String publicLineName;
  final String transportMode;
  final DateTime? scheduledArrival;
  final DateTime? estimatedArrival;
  final bool isDestinationServiced;
}

enum OjpStopEventType { both, arrival }

abstract interface class OjpPublicDirectionClient {
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
    OjpStopEventType eventType = OjpStopEventType.both,
  });
}

class OjpLocationRecord {
  const OjpLocationRecord({required this.name, required this.stopPlaceRef});

  final String name;
  final String stopPlaceRef;
}

abstract interface class OjpLocationClient {
  Future<List<OjpLocationRecord>> fetchLocations({
    required String apiKey,
    required String name,
    required int numberOfResults,
  });
}

class OjpStopEventClient
    implements OjpPublicDirectionClient, OjpLocationClient {
  OjpStopEventClient({OjpHttpPost? httpPost})
    : _httpPost = httpPost ?? http.post;

  static final Uri endpoint = Uri.parse(
    'https://api.opentransportdata.swiss/ojp20',
  );

  final OjpHttpPost _httpPost;

  @override
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
    OjpStopEventType eventType = OjpStopEventType.both,
  }) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final departureOrArrivalTime = from.toUtc().toIso8601String();
    final body =
        '''<?xml version="1.0" encoding="UTF-8"?>
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri" version="2.0">
  <OJPRequest>
    <siri:ServiceRequest>
      <siri:ServiceRequestContext>
        <siri:Language>de</siri:Language>
      </siri:ServiceRequestContext>
      <siri:RequestTimestamp>$timestamp</siri:RequestTimestamp>
      <siri:RequestorRef>Treep</siri:RequestorRef>
      <OJPStopEventRequest>
        <siri:RequestTimestamp>$timestamp</siri:RequestTimestamp>
        <siri:MessageIdentifier>treep-direction</siri:MessageIdentifier>
        <Location>
          <PlaceRef>
            <siri:StopPointRef>${_xmlEscape(stopPointRef)}</siri:StopPointRef>
          </PlaceRef>
          <DepArrTime>$departureOrArrivalTime</DepArrTime>
        </Location>
        <Params>
          <NumberOfResults>$numberOfResults</NumberOfResults>
          <StopEventType>${eventType.name}</StopEventType>
          <IncludePreviousCalls>true</IncludePreviousCalls>
          <IncludeOnwardCalls>false</IncludeOnwardCalls>
          <UseRealtimeData>full</UseRealtimeData>
        </Params>
      </OJPStopEventRequest>
    </siri:ServiceRequest>
  </OJPRequest>
</OJP>''';

    final response = await _httpPost(
      endpoint,
      headers: <String, String>{
        'Authorization': 'Bearer $apiKey',
        'Accept': 'application/xml',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: body,
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw OjpStopEventException('http-${response.statusCode}');
    }

    return parseStopEventRecords(_decodeUtf8Body(response));
  }

  static List<OjpStopEventRecord> parseStopEventRecords(String xml) {
    final document = XmlDocument.parse(xml);
    final records = <OjpStopEventRecord>[];

    for (final result in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'StopEventResult',
    )) {
      final service = _firstDescendant(result, 'Service');
      if (service == null) continue;

      final journeyRef = _elementText(service, 'JourneyRef');
      final operatingDayRef = _elementText(service, 'OperatingDayRef');
      final destination = _firstDescendant(service, 'DestinationText');
      final destinationText = destination == null
          ? ''
          : _elementText(destination, 'Text');
      final thisCall = _firstDescendant(result, 'ThisCall');
      final callAtStop = thisCall == null
          ? null
          : _firstDescendant(thisCall, 'CallAtStop');
      final serviceArrival = callAtStop == null
          ? null
          : _firstDescendant(callAtStop, 'ServiceArrival');
      final publishedServiceName = _firstDescendant(
        service,
        'PublishedServiceName',
      );
      final publicLineName = publishedServiceName == null
          ? _elementText(service, 'PublicCode')
          : _elementText(publishedServiceName, 'Text');
      final mode = _firstDescendant(service, 'Mode');
      final scheduledArrival = serviceArrival == null
          ? null
          : DateTime.tryParse(_elementText(serviceArrival, 'TimetabledTime'));
      final estimatedArrival = serviceArrival == null
          ? null
          : DateTime.tryParse(_elementText(serviceArrival, 'EstimatedTime'));
      final hasPreviousServicedCall = result.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'PreviousCall')
          .any((previousCall) {
            final call = _firstDescendant(previousCall, 'CallAtStop');
            if (call == null) return false;
            return _elementText(call, 'NotServicedStop').toLowerCase() !=
                'true';
          });

      if (journeyRef.isEmpty || operatingDayRef.isEmpty) continue;
      records.add(
        OjpStopEventRecord(
          journeyRef: journeyRef,
          operatingDayRef: operatingDayRef,
          destinationText: destinationText,
          hasPreviousServicedCall: hasPreviousServicedCall,
          stopPointRef: callAtStop == null
              ? ''
              : _elementText(callAtStop, 'StopPointRef'),
          stopPointName: callAtStop == null
              ? ''
              : _textFromNamedContainer(callAtStop, 'StopPointName'),
          publicLineName: publicLineName,
          transportMode: mode == null ? '' : _elementText(mode, 'PtMode'),
          scheduledArrival: scheduledArrival,
          estimatedArrival: estimatedArrival,
          isDestinationServiced:
              callAtStop != null &&
              _elementText(callAtStop, 'NotServicedStop').toLowerCase() !=
                  'true',
        ),
      );
    }

    return records;
  }

  @override
  Future<List<OjpLocationRecord>> fetchLocations({
    required String apiKey,
    required String name,
    required int numberOfResults,
  }) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final body =
        '''<?xml version="1.0" encoding="UTF-8"?>
<OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri" version="2.0">
  <OJPRequest>
    <siri:ServiceRequest>
      <siri:RequestTimestamp>$timestamp</siri:RequestTimestamp>
      <siri:RequestorRef>Treep</siri:RequestorRef>
      <OJPLocationInformationRequest>
        <siri:RequestTimestamp>$timestamp</siri:RequestTimestamp>
        <siri:MessageIdentifier>treep-location</siri:MessageIdentifier>
        <InitialInput><Name>${_xmlEscape(name)}</Name></InitialInput>
        <Restrictions>
          <Type>stop</Type>
          <NumberOfResults>$numberOfResults</NumberOfResults>
        </Restrictions>
      </OJPLocationInformationRequest>
    </siri:ServiceRequest>
  </OJPRequest>
</OJP>''';

    final response = await _httpPost(
      endpoint,
      headers: <String, String>{
        'Authorization': 'Bearer $apiKey',
        'Accept': 'application/xml',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: body,
    ).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw OjpStopEventException('location-http-${response.statusCode}');
    }
    return parseLocationRecords(_decodeUtf8Body(response));
  }

  static List<OjpLocationRecord> parseLocationRecords(String xml) {
    final document = XmlDocument.parse(xml);
    final records = <OjpLocationRecord>[];
    for (final result in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'PlaceResult',
    )) {
      final stop =
          _firstDescendant(result, 'StopPlace') ??
          _firstDescendant(result, 'StopPoint');
      if (stop == null) continue;
      final stopPlaceRef = _elementText(stop, 'StopPlaceRef');
      final stopPointRef = _elementText(stop, 'StopPointRef');
      final reference = stopPlaceRef.isNotEmpty ? stopPlaceRef : stopPointRef;
      final nameNode =
          _firstDescendant(stop, 'StopPlaceName') ??
          _firstDescendant(stop, 'StopPointName') ??
          _firstDescendant(stop, 'Name');
      final displayName = nameNode == null
          ? ''
          : _elementText(nameNode, 'Text');
      if (reference.isEmpty || displayName.isEmpty) continue;
      records.add(
        OjpLocationRecord(name: displayName, stopPlaceRef: reference),
      );
    }
    return records;
  }

  static XmlElement? _firstDescendant(XmlElement root, String localName) {
    for (final node in root.descendants.whereType<XmlElement>()) {
      if (node.name.local == localName) return node;
    }
    return null;
  }

  static String _elementText(XmlElement root, String localName) {
    return _firstDescendant(root, localName)?.innerText.trim() ?? '';
  }

  static String _textFromNamedContainer(XmlElement root, String containerName) {
    final container = _firstDescendant(root, containerName);
    return container == null ? '' : _elementText(container, 'Text');
  }

  static String _xmlEscape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _decodeUtf8Body(http.Response response) {
    return utf8.decode(response.bodyBytes);
  }
}

class OjpStopEventException implements Exception {
  const OjpStopEventException(this.reason);

  final String reason;

  @override
  String toString() => 'OjpStopEventException($reason)';
}
