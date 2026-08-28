import 'dart:async';

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
  });

  final String journeyRef;
  final String operatingDayRef;
  final String destinationText;
}

abstract interface class OjpPublicDirectionClient {
  Future<List<OjpStopEventRecord>> fetchStopEvents({
    required String apiKey,
    required String stopPointRef,
    required DateTime from,
    required int numberOfResults,
  });
}

class OjpStopEventClient implements OjpPublicDirectionClient {
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
          <StopEventType>both</StopEventType>
          <IncludePreviousCalls>false</IncludePreviousCalls>
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
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw OjpStopEventException('http-${response.statusCode}');
    }

    return parseStopEventRecords(response.body);
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

      if (journeyRef.isEmpty || operatingDayRef.isEmpty) continue;
      records.add(
        OjpStopEventRecord(
          journeyRef: journeyRef,
          operatingDayRef: operatingDayRef,
          destinationText: destinationText,
        ),
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

  static String _xmlEscape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

class OjpStopEventException implements Exception {
  const OjpStopEventException(this.reason);

  final String reason;

  @override
  String toString() => 'OjpStopEventException($reason)';
}
