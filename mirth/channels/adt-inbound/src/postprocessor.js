/**
 * Postprocessor des Kanals "ADT Inbound" - baut die Quittung.
 *
 * Laeuft, nachdem alle Ziele durch sind. Erst hier ist bekannt, ob die
 * Nachricht wirklich angekommen ist, und nur deshalb wird die Quittung hier
 * zusammengesetzt und nicht schon im Transformer.
 *
 * Der Rueckgabewert wird zur Antwort des Quell-Connectors, weil dessen
 * Response-Einstellung auf "Postprocessor" steht.
 */

var ackCode = channelMap.get('ackCode') || 'AE';
var ackText = channelMap.get('ackText') || '';
var ackMsh = channelMap.get('ackMsh');

// Ohne MSH-Teil konnte der Transformer die Nachricht nicht lesen. Dann gibt es
// nichts, worauf sich eine saubere Quittung beziehen koennte.
if (!ackMsh) {
    var fallback = DateUtil.getCurrentDate('yyyyMMddHHmmss');
    ackMsh = ['MSH', '^~\\&', 'INTEGRATION', 'HL7LAB', '', '', fallback, '',
              'ACK', 'ACK' + fallback, 'P', '2.5'].join('|');
    ackCode = 'AR';
    ackText = 'Nachricht konnte nicht als HL7 v2 gelesen werden';
}

// Status der Ziele pruefen. ERROR heisst: dieses Ziel hat endgueltig nicht
// geschrieben. QUEUED ist dagegen in Ordnung - die Nachricht liegt sicher in
// der Warteschlange von Mirth und wird erneut versucht; dafuer haben wir sie
// ja vorher im message_log festgehalten.
var failed = [];
var connectorMessages = message.getConnectorMessages();
var iterator = connectorMessages.values().iterator();

while (iterator.hasNext()) {
    var connectorMessage = iterator.next();

    // metaDataId 0 ist der Quell-Connector, der hat keinen Schreibauftrag.
    if (connectorMessage.getMetaDataId() == 0) {
        continue;
    }
    if (String(connectorMessage.getStatus()) === 'ERROR') {
        failed.push(connectorMessage.getConnectorName());
    }
}

if (failed.length > 0) {
    ackCode = 'AE';
    ackText = 'Verarbeitung fehlgeschlagen in: ' + failed.join(', ');
    logger.error('ADT: Quittung AE fuer ' + channelMap.get('controlId') +
                 ' - fehlgeschlagene Ziele: ' + failed.join(', '));
}

var msa = ['MSA', ackCode, channelMap.get('controlId') || '', ackText].join('|');

return ackMsh + '\r' + msa + '\r';
