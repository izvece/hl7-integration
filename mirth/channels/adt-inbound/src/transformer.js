/**
 * Quell-Transformer des Kanals "ADT Inbound".
 *
 * Aufgabe: die eingehende Nachricht pruefen, in ein flaches JSON-Objekt
 * uebersetzen und das Ergebnis in den channelMap legen. Die Ziele (Destinations)
 * sind danach nur noch duenne Datenbank-Aufrufe.
 *
 * Dieses Skript entscheidet NICHT, was mit der Nachricht passiert - es stellt
 * nur fest, ob sie gueltig ist. Das Routing machen die Filter der Ziele.
 */

// Welche ADT-Ereignisse der Kanal annimmt. Alles andere ist kein Fehler des
// Senders, aber auch nicht unsere Zustaendigkeit - es landet begruendet in der
// Fehlerablage, statt still verworfen zu werden.
var ACCEPTED_TRIGGERS = ['A01', 'A02', 'A03', 'A04', 'A08', 'A11', 'A13'];

/**
 * Liest eine Komponente eines HL7-Feldes.
 * Faellt auf den Feldtext zurueck, wenn das Feld nicht in Komponenten
 * zerlegt ist - sonst liefern einfache Felder wie PID-8 nichts.
 */
function comp(segmentName, fieldName, componentNumber) {
    try {
        var segment = msg[segmentName];
        if (segment.length() === 0) {
            return null;
        }
        var field = segment[0][fieldName];
        if (field.length() === 0) {
            return null;
        }
        var component = field[fieldName + '.' + componentNumber];
        var value = (component.length() > 0) ? component.toString() : field.toString();
        value = String(value).replace(/^\s+|\s+$/g, '');
        return value === '' ? null : value;
    } catch (e) {
        return null;
    }
}

/** Ist das Segment ueberhaupt vorhanden? */
function hasSegment(segmentName) {
    try {
        return msg[segmentName].length() > 0;
    } catch (e) {
        return false;
    }
}

/**
 * HL7-Zeitstempel (YYYYMMDD[HHMM[SS]]) nach ISO-8601.
 * Gibt null zurueck, wenn sich nichts Sinnvolles lesen laesst - der Aufrufer
 * entscheidet, ob das ein Fehler ist.
 */
function toIso(hl7Timestamp) {
    if (!hl7Timestamp) {
        return null;
    }
    var digits = String(hl7Timestamp).replace(/[^0-9]/g, '');
    if (digits.length < 8) {
        return null;
    }
    var month = digits.substr(4, 2);
    var day = digits.substr(6, 2);
    // Ein Monat 00 oder Tag 00 kommt in echten Nachrichten vor und ist kein
    // gueltiges Datum - lieber null als ein stillschweigend verschobenes Datum.
    if (month === '00' || day === '00' || parseInt(month, 10) > 12 || parseInt(day, 10) > 31) {
        return null;
    }
    var iso = digits.substr(0, 4) + '-' + month + '-' + day;
    if (digits.length >= 12) {
        iso += ' ' + digits.substr(8, 2) + ':' + digits.substr(10, 2) + ':' +
               (digits.length >= 14 ? digits.substr(12, 2) : '00');
    }
    return iso;
}

/** PV1-3 besteht aus Station^Zimmer^Bett - fuer die Ablage zusammengezogen. */
function assignedLocation() {
    var parts = [];
    for (var i = 1; i <= 3; i++) {
        var part = comp('PV1', 'PV1.3', i);
        if (part) {
            parts.push(part);
        }
    }
    return parts.length > 0 ? parts.join('^') : null;
}

/** Nachname^Vorname aus einem XCN-Feld, z.B. PV1-7 (behandelnder Arzt). */
function personName(segmentName, fieldName) {
    var family = comp(segmentName, fieldName, 2);
    var given = comp(segmentName, fieldName, 3);
    var id = comp(segmentName, fieldName, 1);
    var name = [family, given].filter(function (p) { return p; }).join(', ');
    if (name && id) {
        return name + ' (' + id + ')';
    }
    return name || id;
}

// ---------------------------------------------------------------------------
// Auslesen
// ---------------------------------------------------------------------------

var controlId = comp('MSH', 'MSH.10', 1);
var sendingFacility = comp('MSH', 'MSH.4', 1) || '';
var messageType = comp('MSH', 'MSH.9', 1);
var triggerEvent = comp('MSH', 'MSH.9', 2);
var messageVersion = comp('MSH', 'MSH.12', 1);

var birthDateRaw = comp('PID', 'PID.7', 1);
var birthDateIso = toIso(birthDateRaw);

var event = {
    trigger_event: triggerEvent,
    event_occurred_at: toIso(comp('EVN', 'EVN.2', 1)) || toIso(comp('MSH', 'MSH.7', 1)),
    patient_id: comp('PID', 'PID.3', 1),
    patient_id_authority: comp('PID', 'PID.3', 4),
    last_name: comp('PID', 'PID.5', 1),
    first_name: comp('PID', 'PID.5', 2),
    birth_date: birthDateIso,
    gender: comp('PID', 'PID.8', 1),
    visit_number: comp('PV1', 'PV1.19', 1),
    patient_class: comp('PV1', 'PV1.2', 1),
    assigned_location: assignedLocation(),
    attending_physician: personName('PV1', 'PV1.7'),
    admitted_at: toIso(comp('PV1', 'PV1.44', 1)),
    discharged_at: toIso(comp('PV1', 'PV1.45', 1))
};

// ---------------------------------------------------------------------------
// Pruefung
// ---------------------------------------------------------------------------

var problems = [];

function reject(code, detail) {
    problems.push({ code: code, detail: detail });
}

if (!hasSegment('MSH')) {
    reject('MISSING_SEGMENT', 'MSH fehlt - die Nachricht ist kein HL7 v2');
}
if (!hasSegment('PID')) {
    reject('MISSING_SEGMENT', 'PID fehlt - eine ADT-Nachricht ohne Patient ist nicht verwertbar');
}
if (!controlId) {
    reject('MISSING_CONTROL_ID', 'MSH-10 ist leer - die Nachricht ist nicht nachvollziehbar');
}
if (messageType && messageType !== 'ADT') {
    reject('UNSUPPORTED_MESSAGE_TYPE', 'MSH-9.1 ist "' + messageType + '", dieser Kanal nimmt nur ADT');
}
if (!triggerEvent) {
    reject('MISSING_TRIGGER_EVENT', 'MSH-9.2 ist leer');
} else if (ACCEPTED_TRIGGERS.indexOf(triggerEvent) === -1) {
    reject('UNSUPPORTED_TRIGGER_EVENT',
           'Ereignis "' + triggerEvent + '" wird nicht verarbeitet. Erlaubt: ' + ACCEPTED_TRIGGERS.join(', '));
}
if (!event.patient_id) {
    reject('MISSING_PATIENT_ID', 'PID-3.1 ist leer');
}
if (!event.last_name) {
    reject('MISSING_PATIENT_NAME', 'PID-5.1 (Nachname) ist leer');
}
// Ein fehlendes Geburtsdatum ist zulaessig, ein unlesbares nicht: das deutet
// auf ein kaputtes Quellsystem hin und soll auffallen.
if (birthDateRaw && !birthDateIso) {
    reject('INVALID_BIRTH_DATE', 'PID-7 ist "' + birthDateRaw + '" und damit kein gueltiges Datum');
}
if (triggerEvent === 'A01' && !event.visit_number) {
    reject('MISSING_VISIT_NUMBER', 'Bei einer Aufnahme (A01) muss PV1-19 gesetzt sein');
}

var isValid = problems.length === 0;

// ---------------------------------------------------------------------------
// Ergebnis in den channelMap
// ---------------------------------------------------------------------------

// Schritt 1 bekommt immer denselben Rumpf - unabhaengig davon, ob die
// Nachricht gueltig ist. Der Eingang wird in jedem Fall festgehalten.
var logPayload = {
    control_id: controlId,
    sending_facility: sendingFacility,
    message_type: messageType,
    trigger_event: triggerEvent,
    message_version: messageVersion,
    raw_message: connectorMessage.getRawData()
};

channelMap.put('isValid', isValid);
channelMap.put('controlId', controlId || 'UNBEKANNT');
channelMap.put('triggerEvent', triggerEvent || 'NA');
channelMap.put('logPayload', JSON.stringify(logPayload));
channelMap.put('patientIdForSearch', event.patient_id || '');

if (isValid) {
    // Schritt 2 braucht nur die fachlichen Felder.
    channelMap.put('eventPayload', JSON.stringify(event));
} else {
    // Der erste Fehler ist der gemeldete Grund, alle Fehler stehen in den
    // Details - sonst verliert man bei einer Nachricht mit drei Problemen
    // zwei davon und korrigiert dreimal hintereinander.
    channelMap.put('rejectReason', problems[0].code);
    channelMap.put('rejectDetail', problems[0].detail);
    channelMap.put('rejectDetails', JSON.stringify({
        problems: problems,
        received_at: DateUtil.getCurrentDate("yyyy-MM-dd'T'HH:mm:ssXXX")
    }));
}


// Dateiname fuer die Fehlerablage: alles ausser Buchstaben, Ziffern, - und _
// ersetzen, damit eine manipulierte MSH-10 nicht aus dem Verzeichnis ausbricht.
var safeId = String(controlId || 'unbekannt').replace(/[^A-Za-z0-9_-]/g, '_').substr(0, 60);
channelMap.put('errorFileName',
    DateUtil.getCurrentDate('yyyyMMdd_HHmmss') + '_' + (triggerEvent || 'NA') + '_' + safeId + '.hl7');
// ---------------------------------------------------------------------------
// Vorbereitung der Quittung (ACK)
//
// Hier wird nur der MSH-Teil gebaut und der fachliche Befund hinterlegt.
// Zusammengesetzt wird die Quittung erst im Postprocessor - denn erst dort
// steht fest, ob die Datenbank-Ziele tatsaechlich geschrieben haben. Wuerden
// wir die Quittung schon hier abschicken, bekaeme der Sender ein freundliches
// AA, waehrend die Nachricht in Wahrheit nirgends angekommen ist.
// ---------------------------------------------------------------------------

var ackTimestamp = DateUtil.getCurrentDate('yyyyMMddHHmmss');

// Sender und Empfaenger tauschen in der Quittung die Rollen.
var ackMsh = [
    'MSH',
    '^~\\&',
    comp('MSH', 'MSH.5', 1) || 'INTEGRATION',   // wir waren der Empfaenger
    comp('MSH', 'MSH.6', 1) || 'HL7LAB',
    comp('MSH', 'MSH.3', 1) || '',              // Empfaenger = urspruenglicher Sender
    sendingFacility,
    ackTimestamp,
    '',
    'ACK^' + (triggerEvent || ''),
    'ACK' + ackTimestamp,
    comp('MSH', 'MSH.11', 1) || 'P',
    messageVersion || '2.5'
].join('|');

channelMap.put('ackMsh', ackMsh);

if (isValid) {
    channelMap.put('ackCode', 'AA');
    channelMap.put('ackText', '');
} else {
    // AE = Application Error, inhaltlich abgelehnt. Bewusst kein AR: ein
    // erneuter Versuch mit derselben Nachricht wuerde genauso scheitern,
    // der Sender soll also nicht wiederholen, sondern korrigieren.
    channelMap.put('ackCode', 'AE');
    channelMap.put('ackText', problems[0].code + ': ' + problems[0].detail);
}
