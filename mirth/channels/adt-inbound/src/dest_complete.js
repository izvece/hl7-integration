/**
 * Ziel 2 "Patientendaten schreiben" - Filter: nur gueltige Nachrichten.
 *
 * Scheitert dieser Schritt, bleibt die Zeile im message_log auf "received"
 * stehen. Genau das sieht das Monitoring als haengende Nachricht. Die
 * Warteschlange dieses Ziels ist eingeschaltet, Mirth versucht es also von
 * selbst erneut - und hl7.complete_message() ist darauf vorbereitet.
 */
var dbConn = null;

var logId = channelMap.get('messageLogId');
if (logId === null || logId === undefined || String(logId) === '') {
    throw 'messageLogId fehlt - das Ziel "Eingang festhalten" ist nicht gelaufen';
}

try {
    dbConn = DatabaseConnectionFactory.createDatabaseConnection(
        configurationMap.get('dbDriver'),
        configurationMap.get('dbUrl'),
        configurationMap.get('dbUser'),
        configurationMap.get('dbPassword'));

    var params = new java.util.ArrayList();
    params.add(String(logId));
    params.add(channelMap.get('eventPayload'));

    var rs = dbConn.executeCachedQuery(
        'SELECT hl7.complete_message(CAST(? AS bigint), CAST(? AS jsonb)) AS result',
        params);

    if (!rs.next()) {
        throw 'hl7.complete_message() hat keine Zeile zurueckgegeben';
    }

    var result = JSON.parse(rs.getString('result'));

    if (result.already_done === true) {
        logger.info('ADT: message_log_id=' + logId + ' war schon verarbeitet, nichts zu tun');
    }

    return 'status=' + result.status + ' already_done=' + result.already_done;

} finally {
    if (dbConn !== null) {
        dbConn.close();
    }
}
