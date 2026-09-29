/* Sprachen der Verwaltung.
 *
 * Im Quelltext stehen die deutschen Texte - sie sind zugleich der Schlüssel.
 * Hier steht daneben, wie sie auf Englisch heißen. Damit bleibt der Code
 * lesbar, und eine weitere Sprache ist eine weitere Tabelle.
 *
 * Aufrufen mit t("Alle prüfen"). Fehlt eine Übersetzung, erscheint der
 * deutsche Text - das ist immer noch besser als eine leere Schaltfläche.
 */

export const SPRACHEN = { de: "Deutsch", en: "English" };

const EN = {
  // ---------------------------------------------------------- Navigation
  "Übersicht": "Overview",
  "Kameras": "Cameras",
  "Wand": "Wall",
  "Kamerasuche": "Camera scan",
  "Einstellungen": "Settings",
  "Verwaltung": "Admin",
  "CamGrid – Verwaltung": "CamGrid – Admin",
  "Hauptnavigation": "Main navigation",
  "Menü": "Menu",
  "Zustand der Anlage auf einen Blick": "The whole system at a glance",
  "Adressen, Zugangsdaten und Vorschau": "Addresses, credentials and preview",
  "Monitore, Raster und Zuordnung der Kameras": "Monitors, grids and camera assignment",
  "Kameras im Netz finden und übernehmen": "Find cameras on the network and add them",
  "Anzeige, Zugang, Dienste und Sicherung": "Display, access, services and backup",

  // -------------------------------------------------------------- Kopf
  "gespeichert": "saved",
  "nicht gespeichert": "not saved",
  "wird gespeichert …": "saving …",
  "Speichern fehlgeschlagen": "Saving failed",
  "Speichern": "Save",
  "Anzeige": "Display",
  "Anzeige öffnen": "Open display",
  "Helles oder dunkles Aussehen": "Light or dark appearance",
  "Sprache": "Language",
  "Erst einen Monitor anlegen": "Add a monitor first",
  "erreichbar": "reachable",
  "Streaming": "Streaming",
  "wird geladen …": "loading …",

  // ------------------------------------------------------------ Hinweise
  "Es gilt noch das Standardpasswort. Bitte unter": "The default password is still in use. Please change it under",
  "ändern, sonst kommt jeder im Netz an die Kameras.":
    "— otherwise anyone on the network can reach your cameras.",
  "Jetzt ändern": "Change now",
  "Einstellungen → Zugang": "Settings → Access",

  // ----------------------------------------------------------- Assistent
  "In drei Schritten fertig": "Done in three steps",
  "Kameras finden": "Find cameras",
  "Netzbereich eingeben, den Rest macht die Suche.":
    "Enter a network range, the scan does the rest.",
  "Kamerasuche öffnen": "Open camera scan",
  "Auf die Monitore verteilen": "Spread them across the monitors",
  "Raster wählen, Kameras in die Kacheln setzen.": "Pick a grid, put cameras into the tiles.",
  "Wand einrichten": "Set up the wall",
  "Anzeige prüfen": "Check the display",
  "Die Monitore übernehmen Änderungen von selbst.":
    "The monitors pick up changes by themselves.",

  // ----------------------------------------------------------- Übersicht
  "Kameras erreichbar": "Cameras reachable",
  "Monitore": "Monitors",
  "Kacheln": "tiles",
  "Streaming-Dienst": "Streaming service",
  "läuft": "running",
  "nicht erreichbar": "not reachable",
  "Bildschirmausgänge": "Display outputs",
  "keine erkannt": "none detected",
  "öffnen": "open",
  "Vorschau wird geholt …": "fetching preview …",
  "Platzhalter": "placeholder",
  "Noch keine Kamera eingetragen.": "No camera added yet.",

  // ------------------------------------------------------------- Kameras
  "Kamera": "Camera",
  "Alle prüfen": "Check all",
  "Vorschau erneuern": "Refresh preview",
  "Filtern nach Name oder Adresse": "Filter by name or address",
  "Noch keine Kamera": "No cameras yet",
  "Am schnellsten geht es über die Kamerasuche — sie findet die Kameras im Netz samt Auflösung und Stream-Pfad.":
    "The quickest way is the camera scan — it finds the cameras on your network, "
    + "including resolution and stream path.",
  "Nichts gefunden.": "Nothing found.",
  "keine Adresse": "no address",
  "ohne Adresse": "without address",
  "Auflösung unbekannt": "resolution unknown",
  "auf der Wand": "on the wall",
  "nicht zugeordnet": "not assigned",
  "Prüfen": "Check",
  "Bearbeiten": "Edit",
  "Platzhalter ohne Adresse": "placeholder without address",
  "noch nicht geprüft": "not checked yet",
  "Bild läuft": "picture running",
  "antwortet": "responds",
  "antwortet nicht": "no response",

  // ------------------------------------------------------- Seitenfenster
  "Klicken für ein neues Vorschaubild": "Click for a fresh preview image",
  "Name": "Name",
  "IP-Adresse": "IP address",
  "leer lassen = Platzhalter": "leave empty = placeholder",
  "Benutzer": "User",
  "Passwort": "Password",
  "Vollständige Adresse (hat Vorrang, für Kameras ohne RTSP)":
    "Full address (takes precedence, for cameras without RTSP)",
  "leer = RTSP aus IP und Pfad": "empty = RTSP built from IP and path",
  "Stream-Pfad": "Stream path",
  "Auflösung": "Resolution",
  "unbekannt": "unknown",
  "Kamera anzeigen": "Show camera",
  "Vorschau": "Preview",
  "Löschen": "Delete",
  "Schließen": "Close",
  "wird geprüft …": "checking …",
  "Kein Bild - erst „Prüfen“ versuchen.": "No picture — try “Check” first.",
  "Bild da": "Picture found",
  "vorhanden": "available",
  "Erreichbar (Ports": "Reachable (ports",
  "), aber kein Video. Benutzer, Passwort oder Pfad stimmen nicht.":
    "), but no video. User, password or path are wrong.",
  "Nicht erreichbar": "Not reachable",
  "Keine Kamera mit Adresse.": "No camera with an address.",
  "Kameras werden geprüft …": "checking cameras …",
  "Prüfung fertig.": "Check finished.",
  "Kamera gelöscht.": "Camera deleted.",
  "Löschen fehlgeschlagen": "Deleting failed",
  "Anlegen fehlgeschlagen": "Adding failed",
  "wirklich löschen?": "— really delete?",

  // -------------------------------------------------- Kamera hinzufügen
  "Kamera hinzufügen": "Add camera",
  "IP eintragen und auf": "Enter the IP and press",
  "Hinzufügen": "Add",
  "— Zugangsdaten, Stream-Pfad und Auflösung sucht CamGrid selbst. Kameras ohne RTSP werden dabei erkannt.":
    "— CamGrid works out credentials, stream path and resolution by itself. "
    + "Cameras without RTSP are detected too.",
  "z. B. Halle Nord": "e.g. North hall",
  "Von Hand festlegen (falls nichts gefunden wird)":
    "Set manually (if nothing is found)",
  "Vollständige Adresse": "Full address",
  "rtsp://… oder http://…/video.mjpg": "rtsp://… or http://…/video.mjpg",
  "Die vollständige Adresse hat Vorrang. Damit laufen auch Kameras, die kein RTSP anbieten.":
    "The full address takes precedence. That is how cameras without RTSP work.",
  "Bitte eine IP-Adresse oder eine vollständige Adresse angeben.":
    "Please enter an IP address or a full address.",
  "wird angelegt und geprüft …": "adding and checking …",
  "angelegt": "added",
  "MJPEG über HTTP": "MJPEG over HTTP",
  "angelegt, aber noch kein Video gefunden - Zugangsdaten oder Adresse prüfen.":
    "added, but no video found yet — check credentials or address.",
  "Abbrechen": "Cancel",

  // ---------------------------------------------------------------- Wand
  "Monitor": "Monitor",
  "Rückgängig": "Undo",
  "Ziehen oder Kachel antippen · gespeichert wird auf Knopfdruck":
    "Drag or tap a tile · nothing is saved until you press the button",
  "Auf eine Kachel tippen und die Kamera aus der Liste wählen.":
    "Tap a tile and pick the camera from the list.",
  "noch nicht zugeordnet": "not assigned yet",
  "alle Kameras sind zugeordnet": "all cameras are assigned",
  "Erst Kameras anlegen oder suchen.": "Add or scan for cameras first.",
  "liegt schon auf der Wand": "already on the wall",
  "auf eine Kachel ziehen": "drag onto a tile",
  "Name des Monitors": "Name of the monitor",
  "Ausgang": "Output",
  "automatisch": "automatic",
  "Entfernen": "Remove",
  "Raster:": "Grid:",
  "2 neben": "2 side by side",
  "eigen": "custom",
  "+ Kamera": "+ camera",
  "Breiter": "Wider",
  "Höher": "Taller",
  "Leeren": "Clear",
  "Kamera wählen": "Pick a camera",
  "Kachel leeren": "Clear tile",
  "Platz": "position",
  "Keine Kamera vorhanden.": "No cameras available.",
  "Mindestens ein Monitor muss bleiben.": "At least one monitor has to stay.",
  "entfernen?": "— remove it?",
  "Letzte Änderung an der Wand zurückgenommen.": "Last change to the wall undone.",
  "Gespeichert. Die Monitore übernehmen es in wenigen Sekunden.":
    "Saved. The monitors will pick it up within seconds.",
  "Gespeichert. Streams": "Saved. Streams",

  // --------------------------------------------------------------- Suche
  "Netzbereich": "Network range",
  "Suche starten": "Start scan",
  "Die Suche probiert die üblichen Kamera-Adressen durch. Ein Bereich mit 254 Adressen dauert etwa eine Minute.":
    "The scan tries the usual camera addresses. A range of 254 addresses takes about a minute.",
  "Suche läuft …": "scanning …",
  "Ausgewählte übernehmen": "Add selected",
  "Alle auswählen": "Select all",
  "Kamerapasswort": "Camera password",
  "Bitte einen Netzbereich angeben, z. B. 192.168.1.0/24":
    "Please enter a network range, e.g. 192.168.1.0/24",
  "von": "of",
  "Adressen": "addresses",
  "Fertig ·": "Done ·",
  "Kameras gefunden": "cameras found",
  "Fehler": "Error",
  "Abbruch": "Aborted",
  "Adressen mit Antwort, davon": "addresses responded, of those",
  "mit Videostrom.": "with a video stream.",
  "schon eingetragen": "already added",
  "Hersteller unbekannt": "vendor unknown",
  "kein Video gefunden": "no video found",
  "Pfad": "path",
  "Nichts ausgewählt.": "Nothing selected.",
  "Kameras übernommen.": "cameras added.",

  // ------------------------------------------------------- Einstellungen
  "Name der Anlage": "Name of the installation",
  "Sprache der Anzeigeseite": "Language of the display page",
  "Deutsch": "German",
  "Bildrate (Hz)": "Frame rate (Hz)",
  "Abstand (Pixel)": "Gap (pixels)",
  "Hintergrundfarbe": "Background colour",
  "Rahmen um jede Kachel": "Border around every tile",
  "Kameranamen einblenden": "Show camera names",
  "Zugang": "Access",
  "Admin-Benutzer": "Admin user",
  "Admin-Passwort": "Admin password",
  "Für diese Verwaltung. Nach dem Ändern meldet sich der Browser neu an.":
    "For this admin interface. After changing it the browser asks again.",
  "Anzeige-Benutzer": "Display user",
  "Anzeige-Passwort": "Display password",
  "Nur für den Aufruf der Anzeigeseite von anderen Rechnern. Die Monitore am Gerät selbst brauchen keinen Login.":
    "Only for opening the display page from other computers. The monitors on the "
    + "device itself need no login.",
  "Dienste": "Services",
  "Kameras neu übernehmen": "Re-apply cameras",
  "Anzeige neu starten": "Restart display",
  "„Neu übernehmen“ meldet alle Streams neu an, ohne die Monitore zu unterbrechen.":
    "“Re-apply” registers all streams again without interrupting the monitors.",
  "Sicherung": "Backup",
  "Herunterladen": "Download",
  "Einspielen": "Restore",
  "Die Datei enthält auch die Kamerapasswörter — bitte sicher aufbewahren.":
    "The file contains the camera passwords too — keep it safe.",
  "Die aktuellen Einstellungen werden dadurch ersetzt. Fortfahren?":
    "This replaces the current settings. Continue?",
  "Einstellungen eingespielt.": "Settings restored.",
  "Einspielen fehlgeschlagen": "Restoring failed",
  "Anmeldedaten geändert. Die Seite wird neu geladen - bitte neu anmelden.":
    "Credentials changed. The page reloads — please log in again.",
  "Vorschaubilder werden geholt": "fetching preview images",
  "Vorschau erneuert.": "Preview refreshed.",
  "Konfiguration nicht ladbar": "Cannot load the configuration",
  "Server antwortet nicht": "Server does not answer",

  // ------------------------------------------------------ Auflösungen
  "1920 × 1080 · 60 Hz (empfohlen)": "1920 × 1080 · 60 Hz (recommended)",
  "3840 × 2160 (nur 30 Hz)": "3840 × 2160 (30 Hz only)",
};

const TABELLEN = { de: {}, en: EN };

let aktuell = "en";

export function spracheSetzen(kuerzel) {
  aktuell = TABELLEN[kuerzel] ? kuerzel : "en";
  document.documentElement.lang = aktuell;
  try { localStorage.setItem("camgrid-sprache", aktuell); } catch { /* egal */ }
  return aktuell;
}

export function spracheHolen() {
  try {
    const gemerkt = localStorage.getItem("camgrid-sprache");
    if (gemerkt && TABELLEN[gemerkt]) return gemerkt;
  } catch { /* egal */ }
  // Ohne Wahl: an der Sprache des Browsers orientieren, sonst Englisch.
  return (navigator.language || "en").toLowerCase().startsWith("de") ? "de" : "en";
}

/** Übersetzt einen deutschen Text in die eingestellte Sprache. */
export function t(text) {
  if (aktuell === "de") return text;
  return TABELLEN[aktuell][text] ?? text;
}

/** Übersetzt alles, was im Baum unter `wurzel` sichtbar ist.
 *  Beim ersten Durchlauf wird der deutsche Urtext am Element gemerkt, damit
 *  ein späterer Sprachwechsel nicht auf schon übersetztem Text aufsetzt. */
export function baumUebersetzen(wurzel = document.body) {
  const gehen = document.createTreeWalker(wurzel, NodeFilter.SHOW_TEXT);
  const knoten = [];
  while (gehen.nextNode()) knoten.push(gehen.currentNode);

  for (const knotenPunkt of knoten) {
    const eltern = knotenPunkt.parentElement;
    if (!eltern || eltern.closest("script, style, svg")) continue;
    const roh = knotenPunkt.nodeValue;
    if (!roh || !roh.trim()) continue;

    if (knotenPunkt.__urtext === undefined) knotenPunkt.__urtext = roh;
    const urtext = knotenPunkt.__urtext;
    const gekuerzt = urtext.replace(/\s+/g, " ").trim();
    const uebersetzt = t(gekuerzt);
    if (uebersetzt !== gekuerzt) {
      knotenPunkt.nodeValue = urtext.replace(gekuerzt, uebersetzt);
    } else {
      knotenPunkt.nodeValue = urtext;
    }
  }

  for (const element of wurzel.querySelectorAll("[placeholder], [title], [aria-label]")) {
    for (const merkmal of ["placeholder", "title", "aria-label"]) {
      const wert = element.getAttribute(merkmal);
      if (!wert) continue;
      // dataset-Namen vertragen keine Bindestriche ("aria-label").
      const schluessel = `ur${merkmal.replace(/-/g, "")}`;
      if (element.dataset[schluessel] === undefined) element.dataset[schluessel] = wert;
      element.setAttribute(merkmal, t(element.dataset[schluessel]));
    }
  }
}
