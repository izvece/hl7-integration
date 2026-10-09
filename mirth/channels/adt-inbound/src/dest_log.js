/**
 * Ziel 1 "Eingang festhalten" - laeuft fuer jede Nachricht, ohne Filter.
 *
 * Nach diesem Schritt ist die Nachricht nachweisbar angekommen. Alles
 * Folgende darf scheitern, ohne dass eine Nachricht spurlos verschwindet.
 *
 * Der Database Writer laeuft hier im JavaScript-Modus, nicht im normalen
 * SQL-Modus. Grund: im SQL-Modus setzt Mirth ${variablen} als Text in das
 * Statement ein. Rohe HL7-Nachrichten enthalten Anfuehrungszeichen und
 * Zeilenumbrueche - das waere eine SQL-Injection-Luecke mit Patientendaten
 * als Einfallstor. Hier binden wir die Werte als echte Parameter.
 */
var dbConn = null;

try {
    dbConn = DatabaseConnectionFactory.createDatabaseConnection(
        configurationMap.get('dbDriver'),
        configurationMap.get('dbUrl'),
        configurationMap.get('dbUser'),
        configurationMap.get('dbPassword'));

    var params = new java.util.ArrayList();
    params.add(channelMap.get('logPayload'));

    var rs = dbConn.executeCachedQuery(
        'SELECT hl7.log_message(CAST(? AS jsonb)) AS result', params);

    if (!rs.next()) {
        throw 'hl7.log_message() hat keine Zeile zurueckgegeben';
    }

    var result = JSON.parse(rs.getString('result'));

    // Als Text ablegen: der Wert wandert spaeter wieder als Parameter in die
    // Datenbank, und eine Zahl aus Rhino kaeme dort als Double an.
    channelMap.put('messageLogId', String(result.message_log_id));
    channelMap.put('isDuplicate', result.duplicate === true);

    if (result.duplicate === true) {
        logger.info('ADT: Wiederholung von ' + channelMap.get('controlId') +
                    ', bereits als message_log_id=' + result.message_log_id + ' bekannt');
    }

    return 'message_log_id=' + result.message_log_id + ' duplicate=' + result.duplicate;

} finally {
    if (dbConn !== null) {
        dbConn.close();
    }
}
