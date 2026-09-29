/* Verwaltung von CamGrid.
   Kein Framework, nur Standard-Browsertechnik - läuft auch auf einem alten
   Rechner im Leitstand und ist in zehn Jahren noch wartbar.

   Zwei Regeln, die hier wichtig sind:

   1. Gespeichert wird erst, wenn der Knopf "Speichern" gedrückt wird. Bis
      dahin baut man die Wand in Ruhe zusammen und sieht die Vorschau.
   2. Kein Ereignis merkt sich ein Objekt aus der Konfiguration, sondern immer
      nur dessen Kennung. Sonst zeigen die Kacheln nach einem Speichern auf
      alte Objekte und Änderungen gehen verloren. */

const $ = (auswahl, wurzel = document) => wurzel.querySelector(auswahl);
const $$ = (auswahl, wurzel = document) => [...wurzel.querySelectorAll(auswahl)];

let config = null;         // Arbeitsstand im Browser
let status = null;         // Zustand vom Server
let offen = false;         // gibt es ungespeicherte Änderungen?
let zugangBeimLaden = "";  // um zu merken, wenn die Anmeldedaten geändert wurden
let offeneKamera = null;   // Kennung der Kamera im Seitenfenster

const rueckStapel = [];           // frühere Stände der Wand für "Rückgängig"
const bilder = new Map();         // Kamera-ID -> Objekt-URL des Vorschaubilds
const laufendeBilder = new Map(); // Kamera-ID -> laufende Anfrage

const SEITEN = {
  start: ["Übersicht", "Zustand der Anlage auf einen Blick"],
  kameras: ["Kameras", "Adressen, Zugangsdaten und Vorschau"],
  wand: ["Wand", "Monitore, Raster und Zuordnung der Kameras"],
  suche: ["Kamerasuche", "Kameras im Netz finden und übernehmen"],
  einstellungen: ["Einstellungen", "Anzeige, Zugang, Dienste und Sicherung"],
};

// --------------------------------------------------------------- Server

async function api(pfad, methode = "GET", koerper = null) {
  const antwort = await fetch(`/api/${pfad}`, {
    method: methode,
    headers: koerper ? { "Content-Type": "application/json" } : {},
    body: koerper ? JSON.stringify(koerper) : null,
  });
  if (!antwort.ok) {
    let text = `${antwort.status} ${antwort.statusText}`;
    try {
      const daten = await antwort.json();
      if (daten.fehler) text = daten.fehler;
    } catch { /* keine JSON-Antwort */ }
    throw new Error(text);
  }
  if (antwort.status === 204) return null;
  const typ = antwort.headers.get("Content-Type") || "";
  return typ.includes("json") ? antwort.json() : antwort.blob();
}

function melden(text, art = "") {
  const kasten = $("#meldung");
  kasten.textContent = text;
  kasten.className = `meldung ${art}`;
  kasten.hidden = false;
  clearTimeout(melden.zeit);
  melden.zeit = setTimeout(() => { kasten.hidden = true; }, art === "fehler" ? 8000 : 3000);
}

function aendern() {
  offen = true;
  $("#speichern").disabled = false;
  $("#speicherstand").textContent = "nicht gespeichert";
  $("#speicherstand").className = "speicherstand offen";
}

function alsGespeichert() {
  offen = false;
  $("#speichern").disabled = true;
  $("#speicherstand").textContent = "gespeichert";
  $("#speicherstand").className = "speicherstand";
}

async function speichern(still = false) {
  if (!offen) return true;
  $("#speicherstand").textContent = "wird gespeichert …";
  $("#speicherstand").className = "speicherstand laeuft";
  try {
    const antwort = await api("config", "PUT", config);
    const zugangNeu = JSON.stringify([config.zugang?.admin_benutzer, config.zugang?.admin_passwort]);
    config = antwort.config;
    alsGespeichert();
    allesZeichnen();
    if (zugangBeimLaden && zugangNeu !== zugangBeimLaden) {
      zugangBeimLaden = zugangNeu;
      melden("Anmeldedaten geändert. Die Seite wird neu geladen - bitte neu anmelden.", "gut");
      setTimeout(() => location.reload(), 2500);
      return true;
    }
    if (!still) {
      melden(antwort.streams_uebernommen
        ? "Gespeichert. Die Monitore übernehmen es in wenigen Sekunden."
        : `Gespeichert. Streams: ${antwort.meldung}`, "gut");
    }
    return true;
  } catch (fehler) {
    $("#speicherstand").textContent = "Speichern fehlgeschlagen";
    $("#speicherstand").className = "speicherstand offen";
    melden(`Speichern fehlgeschlagen: ${fehler.message}`, "fehler");
    return false;
  }
}

// ------------------------------------------------------ Zugriff über Kennung

const kameraHolen = (id) => config.kameras.find((k) => k.id === id) || null;
const monitorHolen = (id) => config.monitore.find((m) => Number(m.id) === Number(id)) || null;
const kachelHolen = (monitor, platz) =>
  monitor ? monitor.kacheln.find((k) => k.platz === Number(platz)) || null : null;

function standMerken() {
  rueckStapel.push(JSON.stringify(config.monitore));
  if (rueckStapel.length > 30) rueckStapel.shift();
  $("#rueckgaengig").disabled = false;
}

function rueckgaengig() {
  const vorher = rueckStapel.pop();
  if (!vorher) return;
  config.monitore = JSON.parse(vorher);
  $("#rueckgaengig").disabled = rueckStapel.length === 0;
  aendern();
  wandZeichnen();
  melden("Letzte Änderung an der Wand zurückgenommen.");
}

// ---------------------------------------------------------- Vorschaubilder

function bildSicherstellen(kameraId, erzwingen = false) {
  const kamera = kameraHolen(kameraId);
  if (!kamera || !kamera.ip) return Promise.resolve(null);
  if (bilder.has(kameraId) && !erzwingen) {
    bilderEinsetzen(kameraId);
    return Promise.resolve(bilder.get(kameraId));
  }
  if (laufendeBilder.has(kameraId)) return laufendeBilder.get(kameraId);

  const anfrage = api(`kameras/${kameraId}/bild`)
    .then((blob) => {
      const adresse = URL.createObjectURL(blob);
      const alt = bilder.get(kameraId);
      if (alt) URL.revokeObjectURL(alt);
      bilder.set(kameraId, adresse);
      bilderEinsetzen(kameraId);
      return adresse;
    })
    .catch(() => null)
    .finally(() => laufendeBilder.delete(kameraId));

  laufendeBilder.set(kameraId, anfrage);
  return anfrage;
}

function bilderEinsetzen(kameraId) {
  const adresse = bilder.get(kameraId);
  if (!adresse) return;
  const kennung = window.CSS && CSS.escape ? CSS.escape(kameraId) : kameraId;
  for (const bild of $$(`img[data-kamera="${kennung}"]`)) {
    if (bild.src !== adresse) bild.src = adresse;
    bild.classList.add("da");
  }
}

function bilderAlleEinsetzen() {
  for (const id of bilder.keys()) bilderEinsetzen(id);
}

function fehlendeBilderHolen() {
  for (const id of new Set($$("img[data-kamera]").map((b) => b.dataset.kamera))) {
    if (!bilder.has(id)) bildSicherstellen(id);
  }
}

async function alleBilderErneuern() {
  const mitIp = config.kameras.filter((k) => k.ip);
  if (!mitIp.length) return;
  melden(`Vorschaubilder werden geholt (${mitIp.length}) …`);
  await Promise.all(mitIp.map((k) => bildSicherstellen(k.id, true)));
  melden("Vorschau erneuert.", "gut");
}

/** Farbe und Klartext zum Zustand einer Kamera. go2rtc verbindet sich erst,
    wenn jemand zuschaut - "kein Bild" heißt also nicht, dass sie tot ist. */
function kameraZustand(kamera) {
  const gemeldet = status?.kameras?.find((k) => k.id === kamera.id);
  if (!kamera.ip) return { punkt: "", text: "Platzhalter ohne Adresse" };
  if (!gemeldet) return { punkt: "", text: "noch nicht geprüft" };
  if (gemeldet.verbunden) return { punkt: "laeuft", text: "Bild läuft" };
  if (gemeldet.erreichbar) return { punkt: "gut", text: "antwortet" };
  return { punkt: "schlecht", text: "antwortet nicht" };
}

// ------------------------------------------------------------- Übersicht

function startZeichnen() {
  $("#assistent").hidden = config.kameras.length > 0;

  const erreichbar = status ? status.kameras.filter((k) => k.erreichbar).length : 0;
  const mitAdresse = config.kameras.filter((k) => k.ip).length;
  const dienst = status?.go2rtc_erreichbar;
  const kacheln = config.monitore.reduce((summe, m) => summe + m.kacheln.length, 0);

  $("#statusKarten").innerHTML = `
    <div class="karte">
      <div class="beschriftung">Kameras erreichbar</div>
      <div class="zahl">${erreichbar}
        <span style="color:var(--text-leise);font-size:17px">/ ${mitAdresse}</span></div>
    </div>
    <div class="karte">
      <div class="beschriftung">Monitore</div>
      <div class="zahl">${config.monitore.length}
        <span style="color:var(--text-leise);font-size:17px">· ${kacheln} Kacheln</span></div>
    </div>
    <div class="karte">
      <div class="beschriftung">Streaming-Dienst</div>
      <div class="zahl klein-text"><span class="punkt ${dienst ? "gut" : "schlecht"}"></span>
        ${dienst ? "läuft" : "nicht erreichbar"}</div>
    </div>
    <div class="karte">
      <div class="beschriftung">Bildschirmausgänge</div>
      <div class="zahl klein-text">${sicher(status?.ausgaenge?.join(", ") || "keine erkannt")}</div>
    </div>`;

  // Kleine Vorschau der Wand, damit man die Zuordnung ohne Umweg sieht.
  const port = config.dienste?.go2rtc_port || 1984;
  $("#wandVorschau").innerHTML = config.monitore.map((monitor) => `
    <div class="schirm-karte">
      <div class="schirm-kopf">
        <b>${sicher(monitor.name)}</b>
        <span class="klein">${monitor.spalten} × ${monitor.zeilen}</span>
        <a class="knopf knopf-klein" target="_blank" rel="noreferrer"
           href="http://${sicher(status?.adresse || location.hostname)}:${port}/?monitor=${monitor.id}">öffnen</a>
      </div>
      <div class="monitor-schirm">
        <div class="monitor-raster" style="grid-template-columns:repeat(${monitor.spalten},1fr);
             grid-template-rows:repeat(${monitor.zeilen},1fr)">${vorschauZellen(monitor)}</div>
      </div>
    </div>`).join("");

  $("#uebersichtListe").innerHTML = config.kameras.map((kamera) => {
    const { punkt, text } = kameraZustand(kamera);
    return `
      <div class="uebersicht-kachel">
        <div class="bild">
          <img data-kamera="${sicher(kamera.id)}" alt="">
          <span class="leer">${kamera.ip ? "Vorschau wird geholt …" : "Platzhalter"}</span>
        </div>
        <div class="zeile">
          <span class="punkt ${punkt}"></span>
          <span class="name">${sicher(kamera.name)}</span>
          <span class="klein">${text}</span>
        </div>
      </div>`;
  }).join("") || "<p class='klein'>Noch keine Kamera eingetragen.</p>";
  bilderAlleEinsetzen();
}

/** Zellen für die kleine Wand-Vorschau auf der Startseite (ohne Bedienung). */
function vorschauZellen(monitor) {
  let inhalt = "";
  for (let platz = 1; platz <= monitor.spalten * monitor.zeilen; platz++) {
    if (istVerdeckt(monitor, platz)) continue;
    const kachel = kachelHolen(monitor, platz);
    const kamera = kachel ? kameraHolen(kachel.kamera_id) : null;
    const spanne = kachel ? `grid-column:span ${kachel.breite};grid-row:span ${kachel.hoehe};` : "";
    inhalt += `<div class="zelle ${kachel ? "belegt" : ""}" style="${spanne}cursor:default">
        ${kamera ? `<img class="vorschau" data-kamera="${sicher(kamera.id)}" alt="">` : ""}
        ${kamera ? `<div class="beschriftung-zelle"><div class="zellen-name">${sicher(kamera.name)}</div></div>` : ""}
      </div>`;
  }
  return inhalt;
}

function zustandZeichnen() {
  $("#anlagenname").textContent = config?.anlage?.name || "CamGrid";
  $("#zaehlerKameras").textContent = config ? config.kameras.length : "";

  const leiste = $("#zustandLeiste");
  if (!status) { leiste.innerHTML = ""; return; }
  const erreichbar = status.kameras.filter((k) => k.erreichbar).length;
  const alle = status.kameras.filter((k) => k.ip).length;
  const punkt = alle === 0 ? "" : erreichbar === alle ? "gut" : erreichbar ? "warn" : "schlecht";
  leiste.innerHTML = `
    <span class="marke-zeile"><span class="punkt ${punkt}"></span><b>${erreichbar}/${alle}</b> erreichbar</span>
    <span class="marke-zeile"><span class="punkt ${status.go2rtc_erreichbar ? "gut" : "schlecht"}"></span>Streaming</span>`;
  $("#kopfAdresse").textContent = `${status.adresse} · ${String(status.zeit).slice(11)}`;

  const port = config?.dienste?.go2rtc_port || 1984;
  $("#anzeigeListe").innerHTML = config.monitore.map((monitor) =>
    `<a href="http://${sicher(status.adresse)}:${port}/?monitor=${monitor.id}"
        target="_blank" rel="noreferrer">${sicher(monitor.name)}</a>`).join("")
    || "<a>Erst einen Monitor anlegen</a>";
}

// ---------------------------------------------------------------- Kameras

function kamerasZeichnen() {
  const liste = $("#kameraListe");
  const filter = ($("#kameraSuche").value || "").toLowerCase();

  if (!config.kameras.length) {
    liste.innerHTML = `<div class="leerzustand">
      <h3>Noch keine Kamera</h3>
      <p class="klein">Am schnellsten geht es über die Kamerasuche — sie findet die Kameras im Netz
        samt Auflösung und Stream-Pfad.</p>
      <div class="werkzeugleiste" style="justify-content:center;margin-top:14px">
        <button class="knopf knopf-haupt" data-gehe="suche">Kamerasuche öffnen</button>
      </div></div>`;
    return;
  }

  const kameras = config.kameras.filter((kamera) =>
    !filter || kamera.name.toLowerCase().includes(filter) || (kamera.ip || "").includes(filter));

  if (!kameras.length) {
    liste.innerHTML = `<div class="leerzustand"><p class="klein">Nichts gefunden.</p></div>`;
    return;
  }

  liste.innerHTML = kameras.map((kamera) => {
    const { punkt, text } = kameraZustand(kamera);
    const aufloesung = kamera.breite ? `${kamera.breite} × ${kamera.hoehe}` : "Auflösung unbekannt";
    const verwendet = config.monitore.some((m) => m.kacheln.some((k) => k.kamera_id === kamera.id));
    return `
      <div class="zeile-eintrag" data-id="${sicher(kamera.id)}">
        <div class="zeile-bild">
          <img data-kamera="${sicher(kamera.id)}" alt="">
          <span class="leer">${kamera.ip ? "…" : "ohne Adresse"}</span>
        </div>
        <div class="zeile-text">
          <div class="zeile-name"><span class="punkt ${punkt}"></span>${sicher(kamera.name)}</div>
          <div class="zeile-angabe">
            <span>${sicher(kamera.ip) || "keine Adresse"}</span>
            <span>${sicher(aufloesung)}</span>
            <span>${text}</span>
            <span>${verwendet ? "auf der Wand" : "nicht zugeordnet"}</span>
          </div>
        </div>
        <div class="zeile-knoepfe">
          <button class="knopf knopf-klein" data-tun="pruefen">Prüfen</button>
          <button class="knopf knopf-klein" data-tun="bearbeiten">Bearbeiten</button>
        </div>
      </div>`;
  }).join("");
  bilderAlleEinsetzen();
  fehlendeBilderHolen();
}

/** Seitenfenster mit allen Feldern einer Kamera. */
function kameraFensterOeffnen(kameraId) {
  const kamera = kameraHolen(kameraId);
  if (!kamera) return;
  offeneKamera = kameraId;
  const { text } = kameraZustand(kamera);

  $("#schubladeTitel").textContent = kamera.name || "Kamera";
  $("#schubladeInhalt").innerHTML = `
    <div class="schublade-bild" data-tun="bild">
      <img data-kamera="${sicher(kamera.id)}" alt="">
      <span class="leer">${kamera.ip ? "Klicken für ein neues Vorschaubild" : "keine Adresse"}</span>
    </div>
    <label class="feld">Name <input type="text" data-feld="name" value="${sicher(kamera.name)}"></label>
    <label class="feld">IP-Adresse
      <input type="text" data-feld="ip" value="${sicher(kamera.ip)}"
             placeholder="leer lassen = Platzhalter"></label>
    <div class="feld-paar">
      <label class="feld">Benutzer <input type="text" data-feld="benutzer" value="${sicher(kamera.benutzer)}"></label>
      <label class="feld">Passwort
        <span class="passwortfeld">
          <input type="password" data-feld="passwort" value="${sicher(kamera.passwort)}">
          <button type="button" class="augenknopf">◉</button>
        </span></label>
    </div>
    <label class="feld">Vollständige Adresse (hat Vorrang, für Kameras ohne RTSP)
      <input type="text" data-feld="quelle" value="${sicher(kamera.quelle || "")}"
             placeholder="leer = RTSP aus IP und Pfad"></label>
    <div class="feld-paar">
      <label class="feld">Stream-Pfad
        <input type="text" data-feld="pfad" value="${sicher(kamera.pfad)}" placeholder="stream2"></label>
      <label class="feld">Auflösung
        <input type="text" value="${kamera.breite ? `${kamera.breite} × ${kamera.hoehe}` : "unbekannt"}"
               disabled></label>
    </div>
    <label class="schalter"><input type="checkbox" data-feld="aktiv"
      ${kamera.aktiv !== false ? "checked" : ""}> <span>Kamera anzeigen</span></label>
    <p class="zustand" data-anzeige="zustand">${sicher(text)}</p>
    <div class="werkzeugleiste" style="margin-top:18px">
      <button class="knopf knopf-haupt" data-tun="pruefen">
        <svg class="symbol"><use href="#sym-pruefen"/></svg>Prüfen</button>
      <button class="knopf" data-tun="bild">
        <svg class="symbol"><use href="#sym-bild"/></svg>Vorschau</button>
      <span class="wachsen"></span>
      <button class="knopf knopf-gefahr" data-tun="loeschen">
        <svg class="symbol"><use href="#sym-muell"/></svg>Löschen</button>
    </div>`;

  for (const feld of $$("[data-feld]", $("#schubladeInhalt"))) {
    feld.addEventListener("input", () => {
      const ziel = kameraHolen(offeneKamera);
      if (!ziel) return;
      ziel[feld.dataset.feld] = feld.type === "checkbox" ? feld.checked : feld.value.trim();
      if (feld.dataset.feld === "name") $("#schubladeTitel").textContent = ziel.name || "Kamera";
      aendern();
    });
  }
  bilderAlleEinsetzen();
  fehlendeBilderHolen();
  $("#kameraFenster").hidden = false;
}

function kameraFensterSchliessen() {
  if ($("#kameraFenster").hidden) return;
  $("#kameraFenster").hidden = true;
  offeneKamera = null;
  kamerasZeichnen();
  startZeichnen();
}

function zustandSetzen(text, art = "") {
  const feld = $("[data-anzeige='zustand']");
  if (!feld) return;
  feld.textContent = text;
  feld.className = `zustand ${art}`;
}

async function kameraPruefen(kameraId, alsMeldung = false) {
  if (!alsMeldung) zustandSetzen("wird geprüft …", "laeuft");
  if (offen && !(await speichern(true))) return;
  try {
    const { ergebnis } = await api(`kameras/${kameraId}/pruefen`, "POST");
    const kamera = kameraHolen(kameraId);
    if (!kamera) return;
    if (ergebnis.stream) {
      kamera.breite = ergebnis.stream.breite;
      kamera.hoehe = ergebnis.stream.hoehe;
      if (ergebnis.stream.pfad) kamera.pfad = ergebnis.stream.pfad;
      if (ergebnis.benutzer) kamera.benutzer = ergebnis.benutzer;
      if (ergebnis.passwort) kamera.passwort = ergebnis.passwort;
      const weitere = (ergebnis.weitere_streams || [])
        .map((s) => `${s.pfad} (${s.breite}×${s.hoehe})`).join(", ");
      const text = `Bild da: ${ergebnis.stream.breite} × ${ergebnis.stream.hoehe} `
        + `${ergebnis.stream.codec || ""}` + (weitere ? ` · vorhanden: ${weitere}` : "");
      if (alsMeldung) melden(`${kamera.name}: ${text}`, "gut");
      else zustandSetzen(text, "gut");
      aendern();
      bildSicherstellen(kameraId, true);
    } else {
      const text = ergebnis.erreichbar
        ? `Erreichbar (Ports ${ergebnis.ports.join(", ")}), aber kein Video. `
          + "Benutzer, Passwort oder Pfad stimmen nicht."
        : `Nicht erreichbar${ergebnis.fehler ? `: ${ergebnis.fehler}` : "."}`;
      if (alsMeldung) melden(`${kamera.name}: ${text}`, "fehler");
      else zustandSetzen(text, "schlecht");
    }
  } catch (fehler) {
    if (alsMeldung) melden(fehler.message, "fehler");
    else zustandSetzen(fehler.message, "schlecht");
  }
}

async function kameraVorschau(kameraId) {
  zustandSetzen("Vorschau wird geholt …", "laeuft");
  if (offen && !(await speichern(true))) return;
  const adresse = await bildSicherstellen(kameraId, true);
  const kamera = kameraHolen(kameraId);
  zustandSetzen(adresse ? kameraZustand(kamera).text : "Kein Bild - erst „Prüfen“ versuchen.",
                adresse ? "" : "schlecht");
}

async function kameraLoeschen(kameraId) {
  const kamera = kameraHolen(kameraId);
  if (!kamera || !confirm(`„${kamera.name}“ löschen?`)) return;
  try {
    if (offen && !(await speichern(true))) return;
    const antwort = await api(`kameras/${kameraId}`, "DELETE");
    config = antwort.config;
    bilder.delete(kameraId);
    alsGespeichert();
    kameraFensterSchliessen();
    allesZeichnen();
    melden("Kamera gelöscht.", "gut");
  } catch (fehler) {
    melden(`Löschen fehlgeschlagen: ${fehler.message}`, "fehler");
  }
}

/** Fenster zum Anlegen einer Kamera von Hand. */
function neueKameraOeffnen() {
  for (const kennung of ["neuName", "neuIp", "neuPfad", "neuQuelle"]) $(`#${kennung}`).value = "";
  // Zugangsdaten der letzten Suche vorschlagen - meistens dieselben.
  const letzte = (config.scan?.zugangsdaten || [])[0] || {};
  $("#neuBenutzer").value = letzte.benutzer || "";
  $("#neuPasswort").value = letzte.passwort || "";
  $("#neuZustand").textContent = "";
  $("#neuZustand").className = "zustand";
  $("#neueKamera").hidden = false;
  $("#neuName").focus();
}

function neueKameraSchliessen() {
  $("#neueKamera").hidden = true;
}

/** Legt die Kamera an und prüft sie gleich - so sieht man sofort, ob sie läuft. */
async function neueKameraAnlegen() {
  const eingabe = {
    name: $("#neuName").value.trim() || `Kamera ${config.kameras.length + 1}`,
    ip: $("#neuIp").value.trim(),
    benutzer: $("#neuBenutzer").value.trim(),
    passwort: $("#neuPasswort").value,
    pfad: $("#neuPfad").value.trim(),
    quelle: $("#neuQuelle").value.trim(),
  };
  if (!eingabe.ip && !eingabe.quelle) {
    $("#neuZustand").textContent = "Bitte eine IP-Adresse oder eine vollständige Adresse angeben.";
    $("#neuZustand").className = "zustand schlecht";
    return;
  }
  $("#neuZustand").textContent = "wird angelegt und geprüft …";
  $("#neuZustand").className = "zustand laeuft";

  try {
    if (offen && !(await speichern(true))) return;
    const antwort = await api("kameras", "POST", eingabe);
    config = antwort.config;
    alsGespeichert();
    const neueId = antwort.kamera.id;

    const { ergebnis } = await api(`kameras/${neueId}/pruefen`, "POST");
    const kamera = kameraHolen(neueId);
    if (ergebnis.stream && kamera) {
      kamera.breite = ergebnis.stream.breite || 0;
      kamera.hoehe = ergebnis.stream.hoehe || 0;
      if (ergebnis.stream.pfad) kamera.pfad = ergebnis.stream.pfad;
      if (ergebnis.quelle) kamera.quelle = ergebnis.quelle;
      if (ergebnis.art) kamera.art = ergebnis.art;
      if (ergebnis.benutzer) kamera.benutzer = ergebnis.benutzer;
      if (ergebnis.passwort) kamera.passwort = ergebnis.passwort;
      aendern();
      await speichern(true);
      melden(`„${kamera.name}" angelegt: ` + (ergebnis.art === "mjpeg"
        ? "MJPEG über HTTP" : `${ergebnis.stream.breite} × ${ergebnis.stream.hoehe}`), "gut");
    } else {
      melden(`„${eingabe.name}" angelegt, aber noch kein Video gefunden - `
        + "Zugangsdaten oder Adresse prüfen.", "fehler");
    }
    allesZeichnen();
    bildSicherstellen(neueId, true);
    neueKameraSchliessen();
    reiterWaehlen("kameras");
    kameraFensterOeffnen(neueId);
  } catch (fehler) {
    $("#neuZustand").textContent = fehler.message;
    $("#neuZustand").className = "zustand schlecht";
  }
}

async function kameraAnlegen() {
  try {
    if (offen && !(await speichern(true))) return;
    const antwort = await api("kameras", "POST", { name: `Kamera ${config.kameras.length + 1}` });
    config = antwort.config;
    alsGespeichert();
    allesZeichnen();
    reiterWaehlen("kameras");
    kameraFensterOeffnen(antwort.kamera.id);
  } catch (fehler) {
    melden(`Anlegen fehlgeschlagen: ${fehler.message}`, "fehler");
  }
}

async function alleKamerasPruefen() {
  const ids = config.kameras.filter((k) => k.ip).map((k) => k.id);
  if (!ids.length) { melden("Keine Kamera mit Adresse.", "fehler"); return; }
  melden(`${ids.length} Kameras werden geprüft …`);
  for (const id of ids) await kameraPruefen(id, true);
  kamerasZeichnen();
  melden("Prüfung fertig.", "gut");
}

// -------------------------------------------------------- Wand und Raster

const VORLAGEN = [
  { name: "1", spalten: 1, zeilen: 1 },
  { name: "2 neben", spalten: 2, zeilen: 1 },
  { name: "2×2", spalten: 2, zeilen: 2 },
  { name: "3×2", spalten: 3, zeilen: 2 },
  { name: "3×3", spalten: 3, zeilen: 3 },
  { name: "4×3", spalten: 4, zeilen: 3 },
];

function wandZeichnen() {
  const benutzt = new Set(config.monitore.flatMap((m) => m.kacheln.map((k) => k.kamera_id)));
  const frei = config.kameras.filter((k) => !benutzt.has(k.id));
  $("#zuordnungStand").textContent = config.kameras.length
    ? (frei.length ? `${frei.length} noch nicht zugeordnet` : "alle Kameras sind zugeordnet")
    : "";

  $("#ziehListe").innerHTML = config.kameras.length
    ? config.kameras.map((kamera) => `
        <div class="zieh-kamera${benutzt.has(kamera.id) ? " benutzt" : ""}"
             draggable="true" data-kamera-id="${sicher(kamera.id)}"
             title="${benutzt.has(kamera.id) ? "liegt schon auf der Wand" : "auf eine Kachel ziehen"}">
          <img class="mini" data-kamera="${sicher(kamera.id)}" alt="">
          <div class="text">
            <div>${sicher(kamera.name)}</div>
            <div class="klein">${sicher(kamera.ip) || "ohne Adresse"}</div>
          </div>
        </div>`).join("")
    : "<p class='klein'>Erst Kameras anlegen oder suchen.</p>";

  const behaelter = $("#monitore");
  behaelter.innerHTML = "";
  for (const monitor of config.monitore) behaelter.appendChild(monitorZeichnen(monitor));
  $("#aufloesung").value = config.anzeige.aufloesung;

  bilderAlleEinsetzen();
  fehlendeBilderHolen();
}

function monitorZeichnen(monitor) {
  const kasten = document.createElement("div");
  kasten.className = "monitor";
  kasten.dataset.monitorId = monitor.id;

  const ausgaenge = status?.ausgaenge || [];
  const auswahl = ["", ...ausgaenge].map((wert) =>
    `<option value="${sicher(wert)}" ${wert === monitor.ausgang ? "selected" : ""}>
       ${sicher(wert) || "automatisch"}</option>`).join("");

  kasten.innerHTML = `
    <div class="monitor-kopf">
      <input type="text" value="${sicher(monitor.name)}" data-feld="name" aria-label="Name des Monitors">
      <label class="feld-inline">Ausgang <select data-feld="ausgang">${auswahl}</select></label>
      <span class="wachsen"></span>
      <button class="knopf knopf-klein" data-tun="oeffnen">
        <svg class="symbol"><use href="#sym-extern"/></svg>Anzeige</button>
      <button class="knopf knopf-klein knopf-gefahr" data-tun="loeschen">Entfernen</button>
    </div>
    <div class="vorlagen">
      <span class="klein">Raster:</span>
      ${VORLAGEN.map((v) => `<button class="knopf knopf-klein vorlage-knopf${
        v.spalten === monitor.spalten && v.zeilen === monitor.zeilen ? " aktiv" : ""
      }" data-spalten="${v.spalten}" data-zeilen="${v.zeilen}">${v.name}</button>`).join("")}
      <label class="feld-inline">eigen
        <select data-feld="spalten">${zahlenAuswahl(monitor.spalten)}</select>×
        <select data-feld="zeilen">${zahlenAuswahl(monitor.zeilen)}</select></label>
    </div>
    <div class="monitor-schirm"><div class="monitor-raster"></div></div>`;

  const raster = $(".monitor-raster", kasten);
  raster.style.gridTemplateColumns = `repeat(${monitor.spalten}, 1fr)`;
  raster.style.gridTemplateRows = `repeat(${monitor.zeilen}, 1fr)`;
  for (let platz = 1; platz <= monitor.spalten * monitor.zeilen; platz++) {
    raster.appendChild(zelleZeichnen(monitor, platz));
  }
  return kasten;
}

/** Alle Ereignisse der Wand laufen über Kennungen - so überleben sie jedes
    Neuzeichnen und zeigen nie auf veraltete Objekte. */
function monitorEreignis(ereignis) {
  const kasten = ereignis.target.closest(".monitor");
  if (!kasten) return;
  const monitor = monitorHolen(kasten.dataset.monitorId);
  if (!monitor) return;

  const feld = ereignis.target.closest("[data-feld]");
  if (feld && (ereignis.type === "change" || ereignis.type === "input")) {
    const name = feld.dataset.feld;
    if (name === "spalten" || name === "zeilen") {
      standMerken();
      monitor[name] = Number(feld.value);
      kachelnBegrenzen(monitor);
      aendern();
      wandZeichnen();
      return;
    }
    monitor[name] = feld.value;
    aendern();
    return;
  }
  if (ereignis.type !== "click") return;

  const vorlage = ereignis.target.closest(".vorlage-knopf");
  if (vorlage) {
    standMerken();
    monitor.spalten = Number(vorlage.dataset.spalten);
    monitor.zeilen = Number(vorlage.dataset.zeilen);
    kachelnBegrenzen(monitor);
    aendern();
    wandZeichnen();
    return;
  }

  const knopf = ereignis.target.closest("[data-tun]");
  if (knopf && knopf.dataset.tun === "oeffnen") {
    const port = config.dienste?.go2rtc_port || 1984;
    window.open(`http://${status?.adresse || location.hostname}:${port}/?monitor=${monitor.id}`, "_blank");
    return;
  }
  if (knopf && knopf.dataset.tun === "loeschen") {
    if (config.monitore.length === 1) { melden("Mindestens ein Monitor muss bleiben.", "fehler"); return; }
    if (!confirm(`„${monitor.name}“ entfernen?`)) return;
    standMerken();
    config.monitore = config.monitore.filter((m) => Number(m.id) !== Number(monitor.id));
    aendern();
    wandZeichnen();
    zustandZeichnen();
    return;
  }

  const zelle = ereignis.target.closest(".zelle");
  if (!zelle) return;
  const platz = Number(zelle.dataset.platz);
  const kachel = kachelHolen(monitor, platz);
  const kachelKnopf = ereignis.target.closest(".zellen-knopf");

  if (kachelKnopf && kachel) {
    standMerken();
    const tun = kachelKnopf.dataset.tun;
    if (tun === "breiter") kachel.breite = naechsteGroesse(kachel.breite, monitor.spalten, platz, monitor, "breite");
    if (tun === "hoeher") kachel.hoehe = naechsteGroesse(kachel.hoehe, monitor.zeilen, platz, monitor, "hoehe");
    if (tun === "leeren") monitor.kacheln = monitor.kacheln.filter((k) => k.platz !== platz);
    aendern();
    wandZeichnen();
    return;
  }
  auswahlOeffnen(monitor.id, platz);
}

function zelleZeichnen(monitor, platz) {
  const kachel = monitor.kacheln.find((k) => k.platz === platz);
  const zelle = document.createElement("div");
  zelle.className = "zelle";
  zelle.dataset.platz = platz;

  if (istVerdeckt(monitor, platz)) {
    zelle.style.display = "none";
    return zelle;
  }

  if (kachel) {
    const kamera = kameraHolen(kachel.kamera_id);
    zelle.classList.add("belegt");
    zelle.draggable = true;
    zelle.style.gridColumn = `span ${kachel.breite}`;
    zelle.style.gridRow = `span ${kachel.hoehe}`;
    zelle.innerHTML = `
      ${kamera ? `<img class="vorschau" data-kamera="${sicher(kamera.id)}" alt="">` : ""}
      <div class="beschriftung-zelle">
        <div class="zellen-name">${sicher(kamera ? kamera.name : "Platzhalter")}</div>
        <div class="zellen-ip">${sicher(kamera?.ip || "ohne Adresse")}</div>
      </div>
      <div class="zellen-knoepfe">
        <button class="zellen-knopf" data-tun="breiter" title="Breiter">↔</button>
        <button class="zellen-knopf" data-tun="hoeher" title="Höher">↕</button>
        <button class="zellen-knopf" data-tun="leeren" title="Leeren">✕</button>
      </div>`;
  } else {
    zelle.innerHTML = `<span class="klein">+ Kamera</span>`;
  }
  return zelle;
}

// ------------------------------------------------------------ Ziehen

let ziehGut = null;

function ziehenStart(ereignis) {
  const kamera = ereignis.target.closest(".zieh-kamera");
  if (kamera) {
    ziehGut = { art: "kamera", id: kamera.dataset.kameraId };
    kamera.classList.add("wird-gezogen");
  } else {
    const zelle = ereignis.target.closest(".zelle.belegt");
    if (!zelle) return;
    const monitor = zelle.closest(".monitor");
    if (!monitor) return;
    ziehGut = { art: "kachel", monitor: monitor.dataset.monitorId, platz: Number(zelle.dataset.platz) };
    zelle.classList.add("wird-gezogen");
  }
  ereignis.dataTransfer.effectAllowed = "move";
  try { ereignis.dataTransfer.setData("text/plain", JSON.stringify(ziehGut)); } catch { /* egal */ }
}

function ziehenUeber(ereignis) {
  const zelle = ereignis.target.closest(".zelle");
  if (!zelle || !ziehGut) return;
  ereignis.preventDefault();                 // ohne das lehnt der Browser das Ablegen ab
  ereignis.dataTransfer.dropEffect = "move";
  for (const andere of $$(".zelle.ziel")) andere.classList.remove("ziel");
  zelle.classList.add("ziel");
}

function ziehenAblegen(ereignis) {
  const zelle = ereignis.target.closest(".zelle");
  if (!zelle) return;
  ereignis.preventDefault();
  zelle.classList.remove("ziel");

  let nutzlast = ziehGut;
  if (!nutzlast) {
    try { nutzlast = JSON.parse(ereignis.dataTransfer.getData("text/plain")); } catch { return; }
  }
  const monitorKasten = zelle.closest(".monitor");
  const zielMonitor = monitorKasten ? monitorHolen(monitorKasten.dataset.monitorId) : null;
  const zielPlatz = Number(zelle.dataset.platz);
  if (!zielMonitor || !nutzlast) return;

  standMerken();
  if (nutzlast.art === "kamera") kameraAufPlatz(zielMonitor, zielPlatz, nutzlast.id);
  else if (nutzlast.art === "kachel") kachelVerschieben(nutzlast, zielMonitor, zielPlatz);
  ziehGut = null;
  aendern();
  wandZeichnen();
}

function ziehenEnde() {
  ziehGut = null;
  for (const teil of $$(".wird-gezogen, .zelle.ziel")) teil.classList.remove("wird-gezogen", "ziel");
}

// ------------------------------- Auswahlfenster (Alternative zum Ziehen)

let auswahlZiel = null;

function auswahlOeffnen(monitorId, platz) {
  const monitor = monitorHolen(monitorId);
  if (!monitor) return;
  auswahlZiel = { monitorId, platz };

  $("#auswahlTitel").textContent = `${monitor.name} · Platz ${platz}`;
  $("#auswahlLeeren").hidden = !kachelHolen(monitor, platz);
  $("#auswahlListe").innerHTML = config.kameras.length
    ? config.kameras.map((kamera) => `
        <button class="auswahl-eintrag" data-id="${sicher(kamera.id)}">
          <img class="mini" data-kamera="${sicher(kamera.id)}" alt="">
          <span><b>${sicher(kamera.name)}</b><br>
            <span class="klein">${sicher(kamera.ip) || "ohne Adresse"}</span></span>
        </button>`).join("")
    : "<p class='klein'>Keine Kamera vorhanden.</p>";

  bilderAlleEinsetzen();
  fehlendeBilderHolen();
  $("#auswahl").hidden = false;
}

function auswahlSchliessen() {
  $("#auswahl").hidden = true;
  auswahlZiel = null;
}

function kameraAufPlatz(monitor, platz, kameraId) {
  monitor.kacheln = monitor.kacheln.filter((k) => k.platz !== platz);
  monitor.kacheln.push({ kamera_id: kameraId, platz, breite: 1, hoehe: 1, name: "" });
  monitor.kacheln.sort((a, b) => a.platz - b.platz);
  bildSicherstellen(kameraId);
}

function kachelVerschieben(quelle, zielMonitor, zielPlatz) {
  const quellMonitor = monitorHolen(quelle.monitor);
  if (!quellMonitor) return;
  const kachel = kachelHolen(quellMonitor, quelle.platz);
  if (!kachel) return;
  if (quellMonitor === zielMonitor && kachel.platz === zielPlatz) return;

  const belegt = kachelHolen(zielMonitor, zielPlatz);
  quellMonitor.kacheln = quellMonitor.kacheln.filter((k) => k !== kachel);
  if (belegt) {                                   // Plätze tauschen
    zielMonitor.kacheln = zielMonitor.kacheln.filter((k) => k !== belegt);
    belegt.platz = quelle.platz;
    quellMonitor.kacheln.push(belegt);
  }
  kachel.platz = zielPlatz;
  zielMonitor.kacheln.push(kachel);
  for (const monitor of new Set([quellMonitor, zielMonitor])) {
    monitor.kacheln.sort((a, b) => a.platz - b.platz);
    kachelnBegrenzen(monitor);
  }
}

function naechsteGroesse(jetzt, hoechstens, platz, monitor, richtung) {
  const spalte = ((platz - 1) % monitor.spalten) + 1;
  const zeile = Math.floor((platz - 1) / monitor.spalten) + 1;
  const grenze = richtung === "breite" ? monitor.spalten - spalte + 1 : monitor.zeilen - zeile + 1;
  return jetzt + 1 > Math.min(hoechstens, grenze) ? 1 : jetzt + 1;
}

function istVerdeckt(monitor, platz) {
  const spalte = ((platz - 1) % monitor.spalten) + 1;
  const zeile = Math.floor((platz - 1) / monitor.spalten) + 1;
  return monitor.kacheln.some((kachel) => {
    if (kachel.platz === platz) return false;
    const ks = ((kachel.platz - 1) % monitor.spalten) + 1;
    const kz = Math.floor((kachel.platz - 1) / monitor.spalten) + 1;
    return spalte >= ks && spalte < ks + kachel.breite && zeile >= kz && zeile < kz + kachel.hoehe;
  });
}

function kachelnBegrenzen(monitor) {
  const plaetze = monitor.spalten * monitor.zeilen;
  monitor.kacheln = monitor.kacheln.filter((kachel) => kachel.platz <= plaetze);
  for (const kachel of monitor.kacheln) {
    const spalte = ((kachel.platz - 1) % monitor.spalten) + 1;
    const zeile = Math.floor((kachel.platz - 1) / monitor.spalten) + 1;
    kachel.breite = Math.min(kachel.breite, monitor.spalten - spalte + 1);
    kachel.hoehe = Math.min(kachel.hoehe, monitor.zeilen - zeile + 1);
  }
}

function zahlenAuswahl(gewaehlt) {
  return [1, 2, 3, 4, 5, 6].map((zahl) =>
    `<option value="${zahl}" ${zahl === gewaehlt ? "selected" : ""}>${zahl}</option>`).join("");
}

// ------------------------------------------------------------ Kamerasuche

let scanZeitgeber = null;

async function scanStarten() {
  const netz = $("#scanNetz").value.trim();
  if (!netz) { melden("Bitte einen Netzbereich angeben, z. B. 192.168.1.0/24", "fehler"); return; }
  const zugangsdaten = [{ benutzer: $("#scanBenutzer").value.trim(), passwort: $("#scanPasswort").value }];
  try {
    await api("scan", "POST", { netz, zugangsdaten });
    $("#scanFortschritt").hidden = false;
    $("#scanTreffer").innerHTML = "";
    $("#scanRahmen").hidden = true;
    $("#scanAktionen").hidden = true;
    $("#scanStart").disabled = true;
    scanZeitgeber = setInterval(scanStandHolen, 1000);
    scanStandHolen();
  } catch (fehler) {
    melden(fehler.message, "fehler");
  }
}

async function scanStandHolen() {
  try {
    const stand = await api("scan");
    const anteil = stand.gesamt ? Math.round((stand.fertig / stand.gesamt) * 100) : 0;
    $("#scanBalken").style.width = `${anteil}%`;
    $("#scanText").textContent = stand.laeuft
      ? `${stand.fertig} von ${stand.gesamt} Adressen · ${stand.ip || ""}`
      : stand.fehler ? `Fehler: ${stand.fehler}`
        : `Fertig · ${stand.treffer.length} Kameras gefunden`;
    if (!stand.laeuft) {
      clearInterval(scanZeitgeber);
      $("#scanStart").disabled = false;
      scanTrefferZeichnen(stand.treffer || []);
    }
  } catch (fehler) {
    clearInterval(scanZeitgeber);
    $("#scanStart").disabled = false;
    $("#scanText").textContent = `Abbruch: ${fehler.message}`;
  }
}

function scanTrefferZeichnen(treffer) {
  const bekannt = new Set(config.kameras.map((k) => k.ip).filter(Boolean));
  $("#scanTreffer").innerHTML = treffer.map((fund) => {
    const schonDa = bekannt.has(fund.ip);
    const brauchbar = !!fund.stream;
    const letzte = fund.ip.split(".").pop();
    return `
      <div class="treffer${schonDa ? " schon-da" : ""}${!schonDa && brauchbar ? " gewaehlt" : ""}"
           data-ip="${sicher(fund.ip)}">
        <input type="checkbox" ${schonDa || !brauchbar ? "" : "checked"} ${schonDa ? "disabled" : ""}>
        <div>
          <div class="ip">${sicher(fund.ip)}${schonDa ? " · schon eingetragen" : ""}</div>
          <div class="angabe">${sicher(fund.hersteller || "Hersteller unbekannt")}${
            brauchbar ? ` · ${fund.stream.breite} × ${fund.stream.hoehe} · Pfad „${sicher(fund.stream.pfad)}“`
                      : " · kein Video gefunden"}</div>
        </div>
        <input type="text" class="name" value="${sicher(fund.name || `Kamera ${letzte}`)}"
               ${schonDa ? "disabled" : ""} aria-label="Name">
      </div>`;
  }).join("");

  for (const kasten of $$(".treffer")) {
    const haken = $("input[type=checkbox]", kasten);
    haken.addEventListener("change", () => kasten.classList.toggle("gewaehlt", haken.checked));
  }

  $("#scanRahmen").hidden = !treffer.length;
  $("#scanAktionen").hidden = !treffer.length;
  const brauchbare = treffer.filter((t) => t.stream).length;
  $("#scanZusammenfassung").textContent =
    `${treffer.length} Adressen mit Antwort, davon ${brauchbare} mit Videostrom.`;
}

async function scanUebernehmen() {
  const stand = await api("scan");
  const auswahl = [];
  for (const kasten of $$(".treffer")) {
    if (!$("input[type=checkbox]", kasten).checked) continue;
    const fund = (stand.treffer || []).find((t) => t.ip === kasten.dataset.ip);
    if (fund) auswahl.push({ ...fund, name: $(".name", kasten).value.trim() });
  }
  if (!auswahl.length) { melden("Nichts ausgewählt.", "fehler"); return; }
  try {
    if (offen && !(await speichern(true))) return;
    const antwort = await api("scan/uebernehmen", "POST", { kameras: auswahl });
    config = antwort.config;
    alsGespeichert();
    allesZeichnen();
    melden(`${antwort.hinzugefuegt} Kameras übernommen.`, "gut");
    reiterWaehlen("wand");
  } catch (fehler) {
    melden(fehler.message, "fehler");
  }
}

// --------------------------------------------------------- Einstellungen

const FELDER = [
  ["#setAnlage", "anlage", "name", "text"],
  ["#setBildrate", "anzeige", "bildrate", "zahl"],
  ["#setAbstand", "anzeige", "abstand", "zahl"],
  ["#setRand", "anzeige", "rand", "schalter"],
  ["#setBeschriftung", "anzeige", "beschriftung", "schalter"],
  ["#setHintergrund", "anzeige", "hintergrund", "text"],
  ["#setAdminBenutzer", "zugang", "admin_benutzer", "text"],
  ["#setAdminPasswort", "zugang", "admin_passwort", "text"],
  ["#setAnzeigeBenutzer", "zugang", "anzeige_benutzer", "text"],
  ["#setAnzeigePasswort", "zugang", "anzeige_passwort", "text"],
];

function einstellungenZeichnen() {
  for (const [auswahl, bereich, schluessel, art] of FELDER) {
    const feld = $(auswahl);
    const wert = config[bereich][schluessel];
    if (art === "schalter") feld.checked = wert !== false;
    else feld.value = wert ?? "";
  }
}

function einstellungenVerbinden() {
  for (const [auswahl, bereich, schluessel, art] of FELDER) {
    $(auswahl).addEventListener("change", (ereignis) => {
      const feld = ereignis.target;
      config[bereich][schluessel] =
        art === "schalter" ? feld.checked : art === "zahl" ? Number(feld.value) : feld.value;
      aendern();
      if (schluessel === "name") zustandZeichnen();
    });
  }
}

function sicherungSpeichern() {
  const adresse = URL.createObjectURL(
    new Blob([JSON.stringify(config, null, 2)], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = adresse;
  link.download = `camgrid-${new Date().toISOString().slice(0, 10)}.json`;
  link.click();
  URL.revokeObjectURL(adresse);
}

async function sicherungLaden(datei) {
  if (!datei) return;
  if (!confirm("Die aktuellen Einstellungen werden dadurch ersetzt. Fortfahren?")) return;
  try {
    const antwort = await api("config", "PUT", JSON.parse(await datei.text()));
    config = antwort.config;
    alsGespeichert();
    allesZeichnen();
    melden("Einstellungen eingespielt.", "gut");
  } catch (fehler) {
    melden(`Einspielen fehlgeschlagen: ${fehler.message}`, "fehler");
  }
}

// -------------------------------------------------------------- Rahmen

function sicher(text) {
  return String(text ?? "").replace(/[&<>"']/g, (z) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[z]);
}

function themaSetzen(wahl) {
  if (wahl === "system") document.documentElement.removeAttribute("data-thema");
  else document.documentElement.setAttribute("data-thema", wahl);
  try { localStorage.setItem("camgrid-thema", wahl); } catch { /* egal */ }
  $("#thema").title = `Aussehen: ${wahl === "system" ? "wie das Betriebssystem" : wahl}`;
}

function themaWechseln() {
  let jetzt = "system";
  try { jetzt = localStorage.getItem("camgrid-thema") || "system"; } catch { /* egal */ }
  themaSetzen({ system: "dunkel", dunkel: "hell", hell: "system" }[jetzt]);
}

function passwortHinweisZeigen() {
  const standard = ["camgrid", "camgrid", "admin", "", "demo"];
  $("#passwortHinweis").hidden = !standard.includes(config?.zugang?.admin_passwort ?? "");
}

function reiterWaehlen(ziel) {
  $$(".reiter-knopf").forEach((k) => k.classList.toggle("aktiv", k.dataset.ziel === ziel));
  $$(".seite").forEach((seite) => seite.classList.toggle("aktiv", seite.id === ziel));
  const [titel, hinweis] = SEITEN[ziel] || ["", ""];
  $("#seitentitel").textContent = titel;
  $("#seitenhinweis").textContent = hinweis;
  $("#seitenleiste").classList.remove("offen");

  if (!config) return;
  if (ziel === "start") startZeichnen();
  if (ziel === "kameras") kamerasZeichnen();
  if (ziel === "wand") wandZeichnen();
  fehlendeBilderHolen();
}

function allesZeichnen() {
  passwortHinweisZeigen();
  zustandZeichnen();
  startZeichnen();
  kamerasZeichnen();
  wandZeichnen();
  einstellungenZeichnen();
}

async function standHolen() {
  try {
    status = await api("status");
    zustandZeichnen();
    if ($("#start").classList.contains("aktiv")) startZeichnen();
  } catch (fehler) {
    $("#kopfAdresse").textContent = `Server antwortet nicht: ${fehler.message}`;
  }
}

async function starten() {
  try {
    config = await api("config");
  } catch (fehler) {
    document.body.innerHTML =
      `<div style="padding:40px">Konfiguration nicht ladbar: ${sicher(fehler.message)}</div>`;
    return;
  }
  try { themaSetzen(localStorage.getItem("camgrid-thema") || "system"); }
  catch { themaSetzen("system"); }

  $("#scanNetz").value = config.scan?.netz || "";
  const erste = (config.scan?.zugangsdaten || [])[0] || {};
  $("#scanBenutzer").value = erste.benutzer || "";
  $("#scanPasswort").value = erste.passwort || "";

  zugangBeimLaden = JSON.stringify([config.zugang?.admin_benutzer, config.zugang?.admin_passwort]);
  einstellungenVerbinden();
  alsGespeichert();
  reiterWaehlen("start");
  allesZeichnen();
  await standHolen();
  setInterval(standHolen, 10000);
  fehlendeBilderHolen();
}

// ------------------------------------------------------------ Ereignisse

const wandSeite = $("#wand");
wandSeite.addEventListener("dragstart", ziehenStart);
wandSeite.addEventListener("dragover", ziehenUeber);
wandSeite.addEventListener("drop", ziehenAblegen);
wandSeite.addEventListener("dragend", ziehenEnde);
wandSeite.addEventListener("click", monitorEreignis);
wandSeite.addEventListener("change", monitorEreignis);
wandSeite.addEventListener("input", monitorEreignis);

// Kameraliste: Zeile öffnet das Seitenfenster, "Prüfen" wirkt direkt.
$("#kameraListe").addEventListener("click", (ereignis) => {
  const zeile = ereignis.target.closest(".zeile-eintrag");
  if (!zeile) return;
  const knopf = ereignis.target.closest("[data-tun]");
  if (knopf?.dataset.tun === "pruefen") {
    ereignis.stopPropagation();
    kameraPruefen(zeile.dataset.id, true);
    return;
  }
  kameraFensterOeffnen(zeile.dataset.id);
});

$("#schubladeZu").addEventListener("click", kameraFensterSchliessen);
$("#kameraFenster").addEventListener("click", (ereignis) => {
  if (ereignis.target.id === "kameraFenster") { kameraFensterSchliessen(); return; }
  const knopf = ereignis.target.closest("[data-tun]");
  if (!knopf || !offeneKamera) return;
  if (knopf.dataset.tun === "pruefen") kameraPruefen(offeneKamera);
  if (knopf.dataset.tun === "bild") kameraVorschau(offeneKamera);
  if (knopf.dataset.tun === "loeschen") kameraLoeschen(offeneKamera);
});

document.addEventListener("click", (ereignis) => {
  const ziel = ereignis.target.closest("[data-gehe]");
  if (ziel) reiterWaehlen(ziel.dataset.gehe);

  const auge = ereignis.target.closest(".augenknopf");
  if (auge) {
    const feld = auge.dataset.zeigt ? $(`#${auge.dataset.zeigt}`) : auge.previousElementSibling;
    if (feld) {
      feld.type = feld.type === "password" ? "text" : "password";
      auge.classList.toggle("an", feld.type === "text");
    }
  }

  const eintrag = ereignis.target.closest(".auswahl-eintrag");
  if (eintrag && auswahlZiel) {
    const monitor = monitorHolen(auswahlZiel.monitorId);
    if (monitor) {
      standMerken();
      kameraAufPlatz(monitor, auswahlZiel.platz, eintrag.dataset.id);
      aendern();
      wandZeichnen();
    }
    auswahlSchliessen();
  }

  if (!ereignis.target.closest("#anzeigeMenue")) $("#anzeigeListe").hidden = true;
  if (ereignis.target.id === "auswahl") auswahlSchliessen();
  if (ereignis.target.id === "neueKamera") neueKameraSchliessen();
  if (!ereignis.target.closest("#seitenleiste, #menueKnopf")) {
    $("#seitenleiste").classList.remove("offen");
  }
});

document.addEventListener("keydown", (ereignis) => {
  if (ereignis.key === "Escape") {
    auswahlSchliessen();
    neueKameraSchliessen();
    kameraFensterSchliessen();
    $("#anzeigeListe").hidden = true;
  }
  if ((ereignis.ctrlKey || ereignis.metaKey) && ereignis.key === "z") {
    ereignis.preventDefault();
    rueckgaengig();
  }
  if ((ereignis.ctrlKey || ereignis.metaKey) && ereignis.key === "s") {
    ereignis.preventDefault();
    speichern();
  }
});

$("#reiter").addEventListener("click", (ereignis) => {
  const knopf = ereignis.target.closest(".reiter-knopf");
  if (knopf) reiterWaehlen(knopf.dataset.ziel);
});
$("#menueKnopf").addEventListener("click", () => $("#seitenleiste").classList.toggle("offen"));
$("#speichern").addEventListener("click", () => speichern());
$("#thema").addEventListener("click", themaWechseln);
$("#rueckgaengig").addEventListener("click", rueckgaengig);
$("#anzeigeKnopf").addEventListener("click", () => {
  const liste = $("#anzeigeListe");
  liste.hidden = !liste.hidden;
});
$("#assistentAnzeige").addEventListener("click", () => $("#anzeigeKnopf").click());
$("#kameraNeu").addEventListener("click", neueKameraOeffnen);
$("#kamerasPruefen").addEventListener("click", alleKamerasPruefen);
$("#bilderHolen").addEventListener("click", () => alleBilderErneuern());
$("#kameraSuche").addEventListener("input", kamerasZeichnen);
$("#monitorNeu").addEventListener("click", () => {
  standMerken();
  const naechste = Math.max(0, ...config.monitore.map((m) => Number(m.id))) + 1;
  config.monitore.push({ id: naechste, name: `Monitor ${naechste}`, ausgang: "",
                         spalten: 2, zeilen: 2, kacheln: [] });
  aendern();
  wandZeichnen();
  zustandZeichnen();
});
$("#aufloesung").addEventListener("change", (ereignis) => {
  config.anzeige.aufloesung = ereignis.target.value;
  aendern();
});
$("#scanStart").addEventListener("click", scanStarten);
$("#scanUebernehmen").addEventListener("click", scanUebernehmen);
$("#scanAlle").addEventListener("click", () => {
  for (const kasten of $$(".treffer")) {
    const haken = $("input[type=checkbox]", kasten);
    if (!haken.disabled) { haken.checked = true; kasten.classList.add("gewaehlt"); }
  }
});
$("#neuAbbrechen").addEventListener("click", neueKameraSchliessen);
$("#neuAnlegen").addEventListener("click", neueKameraAnlegen);
$("#auswahlAbbrechen").addEventListener("click", auswahlSchliessen);
$("#auswahlLeeren").addEventListener("click", () => {
  if (!auswahlZiel) return;
  const monitor = monitorHolen(auswahlZiel.monitorId);
  if (monitor) {
    standMerken();
    monitor.kacheln = monitor.kacheln.filter((k) => k.platz !== auswahlZiel.platz);
    aendern();
    wandZeichnen();
  }
  auswahlSchliessen();
});
$("#dienstAnwenden").addEventListener("click", async () => {
  try { melden((await api("anwenden", "POST")).meldung, "gut"); }
  catch (fehler) { melden(fehler.message, "fehler"); }
});
$("#kioskNeustart").addEventListener("click", async () => {
  try { melden((await api("kiosk/neustart", "POST")).meldung, "gut"); }
  catch (fehler) { melden(fehler.message, "fehler"); }
});
$("#sicherungSpeichern").addEventListener("click", sicherungSpeichern);
$("#sicherungLaden").addEventListener("change", (ereignis) => sicherungLaden(ereignis.target.files[0]));

window.addEventListener("beforeunload", (ereignis) => {
  if (offen) { ereignis.preventDefault(); ereignis.returnValue = ""; }
});

/* Zugang von außen - für den Browsertest und die Fehlersuche.
   In der Browserkonsole zeigt `camgrid.config` den aktuellen Stand. */
window.camgrid = {
  get config() { return config; },
  get status() { return status; },
  get ungespeichert() { return offen; },
  speichern,
  neuZeichnen: allesZeichnen,
};
window.camgrid = window.camgrid;      // alter Name, damit nichts bricht
window.__fehler = [];
window.addEventListener("error", (e) => window.__fehler.push(String(e.message)));
window.addEventListener("unhandledrejection", (e) => window.__fehler.push(String(e.reason)));

starten();
