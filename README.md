# Voce

Dettatura vocale locale per vibe coding su macOS (Apple Silicon): tieni premuto **⌘ destro**, parla in italiano
con termini tecnici inglesi, rilascia e il testo compare nel campo attivo. Progetto: [SOLUTION_DESIGN.md](SOLUTION_DESIGN.md).

- **ASR**: Parakeet (TDT 0.6B, ANE) via [FluidAudio](https://github.com/FluidInference/FluidAudio), batch al rilascio del tasto,
  boosting CTC con il dizionario personale. Default **Parakeet Ultra** (post-training di v3 con la stessa architettura e velocità,
  WER più basso su tutte le lingue FLEURS); v3 resta selezionabile. Il boosting usa un encoder CTC inglese da 110M in
  parallelo al TDT: costa ~115 ms su M2 e si disattiva in Impostazioni (`vocabBoost`) se `eval.py` mostra che non serve.
- **Post-processing**: regole deterministiche + dizionario su tutti i profili; LLM (endpoint compatibile OpenAI) solo su chat/email e Command Mode.
- **Inserimento**: clipboard + `⌘V` sintetico con ripristino completo della clipboard.

## Build e installazione

Requisiti: Mac Apple Silicon, macOS 15+, Xcode 26+.

```bash
scripts/setup-signing.sh
```

Una tantum, consigliato: crea un'identità di firma locale stabile in un keychain dedicato, così i permessi di Accessibilità e
Monitoraggio input sopravvivono alle ricompilazioni (con la firma ad-hoc vanno ri-concessi a ogni build).

```bash
scripts/build.sh --install
```

Compila in release, crea `build/Voce.app`, la copia in `~/Applications` e la avvia.

Al primo avvio si apre la finestra di Voce sulla **Panoramica**: concedi Microfono, Accessibilità e Monitoraggio input e attendi
il download del modello (~700 MB, una sola volta, in `~/Library/Application Support/FluidAudio/Models`). Da Impostazioni puoi
attivare **Apri Voce al login**.

## Interfaccia

- **Barra dei menu**: l'icona a barre cambia con lo stato (pronto, in preparazione, in ascolto in rosso, elaborazione, pallino
  se manca un permesso o il tasto non è attivo). Il menu mostra lo stato, l'ultima dettatura (re-incolla, copia) e apre la finestra.
- **HUD** in basso al centro: waveform live del microfono e timer mentre parli, barre animate durante la trascrizione, poi
  l'anteprima del testo inserito. Avvisa se non sente nulla ("Non ti sento: controlla il microfono") e non compare quando usi
  `⌘` destro come modificatore (⌘C, ⌘Tab…).
- **Finestra** (menu → Apri Voce, oppure doppio clic su Voce.app): sidebar stile Impostazioni di Sistema. Panoramica (stato,
  permessi, scorciatoie, funzioni con il loro stato, oggi), Cronologia (per giorno, ricerca nella toolbar), Dizionario,
  Scorciatoie, Funzioni AI, Generale. Mentre è aperta Voce compare nel Dock e in `⌘Tab`. Una pagina = un file in `Voce/Pages/`,
  registrata in `Navigation.Page` + `PageView` (`MainWindow.swift`).
- **Funzioni AI** (facoltative): un servizio (LM Studio/Ollama sul Mac, oppure Groq, Cerebras, Gemini, Claude, OpenAI,
  OpenRouter o un endpoint compatibile OpenAI) con chiave nel Portachiavi, una per servizio; riscrittura per categoria di app;
  comandi sul testo selezionato, anche con un servizio dedicato. Stato verificato con `GET /v1/models`, «Prova» fa una richiesta vera.

## Uso

| Gesto | Effetto |
|---|---|
| Tieni premuto `⌘` destro (oppure `⌥`/`⌃` destro, `Fn` o qualunque tasto/combinazione registrata in Scorciatoie: modificatori sinistri, F1–F20, 🎤, Menu delle tastiere PC, `⌃⌥Spazio`…) | Push-to-talk: rilascia per incollare |
| Tasto + `Spazio` (oppure doppio tap, da Scorciatoie) | Hands-free: un altro tap chiude, `Esc` annulla. Il doppio tap di ⌘ è la scorciatoia predefinita di Siri, per questo non è il default |
| `⌘` destro + `⇧` su testo selezionato (con gli altri tasti: tasto + `⌘`, o il primo modificatore libero) | Command Mode: l'istruzione detta trasforma la selezione (LLM) |
| `⌃⌥V` | Re-incolla l'ultima dettatura |
| "a capo" / "nuovo paragrafo" | `\n` (`⇧↩` nei terminali) / `\n\n` |
| "invia" a fine dettatura | Invio (opt-in, solo profili agent) |

Un tasto premuto mentre tieni il tasto di dettatura (es. `⌘C`) annulla la registrazione: era una scorciatoia, non una dettatura.

> Il tasto 🌐/Fn su alcune configurazioni di macOS 26 non viene consegnato alle app (né agli event tap né via HID):
> per questo il default è `⌘` destro. Voce legge Fn sia dal tap sia da IOHIDManager, se vuoi riprovarlo.
> Sulle tastiere non Apple Fn non arriva mai al Mac (lo gestisce il firmware): registra un altro tasto.
>
> Tastiere e layout: il tasto si confronta per keyCode fisico, i modificatori senza bit destro/sinistro (alcune tastiere
> esterne, remapper) ricadono sul flag generico, e `⌘V`/`⌘C` sintetici usano il tasto che dà V/C nel layout attivo
> (su Dvorak non è la posizione ANSI). I tasti che scrivono un carattere si accettano solo con `⌃` o `⌘`.

**Profili** (dal bundle ID dell'app attiva): `agentIDE` (Cursor, VS Code, Windsurf, Zed), `agentTerminal` (Terminal, iTerm2,
Ghostty, Warp), `chat` (Slack, Discord, Telegram, WhatsApp), `email` (Mail, Outlook), `plain`.

## File

| Percorso | Contenuto |
|---|---|
| `~/.voce/dictionary.json` | `terms` (boosting + forme parlate automatiche) e `replace` (varianti fonetiche). Si modifica dalla pagina Dizionario o a mano; ricaricato a ogni modifica |
| `~/.voce/log.jsonl` | Una riga per dettatura: `ts`, `app`, `profile`, `raw`, `final`, `ms`, `asr_ms`, `llm_ms`, `guardrail` |
| `~/.voce/hang-<ts>.txt` | Solo se l'interfaccia resta bloccata più di 3 s: campionamento dello stack (uno per avvio) per capire dove |
| `~/voce-dataset/` | Con `saveSamples`: `<ts>.wav` + `<ts>.txt` per la valutazione |

Nella pagina **Dizionario**: *Termini* mostra anche le forme parlate riconosciute in automatico; *Correzioni* propone le parole
dell'ultima dettatura (o di una scelta dalla Cronologia) come chip cliccabili per creare "trascritto come → scrivi" in due clic;
la barra **Prova** in fondo applica il dizionario a una frase di esempio. Se il JSON scritto a mano non è valido l'editor resta in
sola lettura invece di sovrascriverlo.

```json
{
  "terms":   ["Claude Code", "Supabase", "useEffect", "kubectl", "PostgreSQL", "Next.js"],
  "replace": { "cube cuttle": "kubectl", "postgres q l": "PostgreSQL" }
}
```

## LLM (chat, email, Command Mode)

Pagina **Funzioni AI**. Qualsiasi endpoint compatibile OpenAI: `{baseURL}/v1/chat/completions`, oppure `{baseURL}/chat/completions`
se l'indirizzo contiene già una versione (`…/v1`, Gemini `…/v1beta/openai`). Preset (modelli verificati a ottobre 2026):

| Servizio | Base URL | Riscrittura | Comandi |
|---|---|---|---|
| LM Studio (default) | `http://localhost:1234` | `qwen3-1.7b` (attiva "keep model loaded") | `qwen3-4b` |
| Ollama | `http://localhost:11434` | `qwen3:1.7b` (`OLLAMA_KEEP_ALIVE=-1`) | `qwen3:4b` |
| Groq | `https://api.groq.com/openai` | `openai/gpt-oss-20b` | `openai/gpt-oss-120b` |
| Cerebras | `https://api.cerebras.ai/v1` | `gpt-oss-120b` | `gpt-oss-120b` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3.5-flash-lite` | `gemini-3.8-flash` |
| Anthropic Claude | `https://api.anthropic.com/v1` | `claude-haiku-4-5` | `claude-haiku-4-5` |
| OpenAI | `https://api.openai.com/v1` | `gpt-6-luna` | `gpt-6-luna` |
| OpenRouter | `https://openrouter.ai/api/v1` | `openai/gpt-oss-20b` | `openai/gpt-oss-120b` |

Groq ha spento `llama-3.1-8b-instant` e `llama-3.3-70b-versatile` il 16/08/2026: all'avvio Voce li sostituisce con gpt-oss.
`reasoning_effort` è `low` per gpt-oss/Gemini/GPT-6 e `none` per GPT-6 Luna; con Qwen3 si aggiunge `/no_think`.

Le chiavi API stanno nel Keychain, una per servizio (account `llm-api-key:<host>`), e vanno solo a servizi non locali. Se l'LLM
fallisce, supera il timeout o viola un guardrail (lunghezza fuori da 0,4–1,6×, preamboli tipo "Ecco"/"Sure", meno del 50% di
parole conservate) si incolla l'output delle regole.

## Valutazione

```bash
python3 tools/eval.py --show-errors
```

Richiede `pip install jiwer`. Attiva `saveSamples`, detta 100–200 campioni, correggi i `.txt` a mano e rinominali in
`<ts>.ref.txt`. Lo script confronta Parakeet grezzo vs boosting + dizionario (`--models ultra v3` per i due checkpoint,
`--whisper` per Whisper turbo) e riporta WER, Term Accuracy, latenza p50/p95 e guardrail rate dal log.

Trascrizione da riga di comando (la stessa pipeline dell'app, senza LLM):

```bash
build/Voce.app/Contents/MacOS/Voce transcribe --model ultra file.wav
```

## Test

```bash
swift test
```

## Icona e snapshot della UI

`Voce/AppIcon.icns` si rigenera con `swift tools/make-icon.swift` (stessa forma dell'icona di menu bar in `Voce/Brand.swift`).
`build/Voce.app/Contents/MacOS/Voce snapshot <cartella>` renderizza HUD, icone di menu bar e pagine in PNG senza permessi di
registrazione schermo (NavigationSplitView, ScrollView e Form offscreen escono vuote: si renderizza il contenuto).

## Licenze

Parakeet TDT è di NVIDIA, CC-BY-4.0 (richiede attribuzione). FluidAudio è Apache 2.0.
