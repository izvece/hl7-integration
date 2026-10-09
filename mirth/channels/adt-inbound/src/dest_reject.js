/**
 * Ziel 3 "Fehlerablage (Datenbank)" - Filter: nur ungueltige Nachrichten.
 *
 * Setzt den Status auf "error" und legt einen Eintrag in hl7.message_error an.
 * Die Nachricht verschwindet dabei nicht aus dem message_log: eine abgelehnte
 * Nachricht ist angekommen und muss in jeder Zaehlung auftauchen.
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
    params.add(String(channelMap.get('rejectReason')));
    params.add(String(channelMap.get('rejectDetails')));

    var rs = dbConn.executeCachedQuery(
        'SELECT hl7.reject_message(CAST(? AS bigint), CAST(? AS text), CAST(? AS jsonb)) AS result',
        params);

    if (!rs.next()) {
        throw 'hl7.reject_message() hat keine Zeile zurueckgegeben';
    }

    var result = JSON.parse(rs.getString('result'));

    logger.warn('ADT abgelehnt: ' + channelMap.get('controlId') +
                ' Grund=' + channelMap.get('rejectReason') +
                ' (' + channelMap.get('rejectDetail') + ')');

    return 'error_id=' + result.error_id;

} finally {
    if (dbConn !== null) {
        dbConn.close();
    }
}
