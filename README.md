# Jarvisol V2 — Source de développement

Ce dépôt contient les **sources de Jarvisol V2** correspondant à la baseline
de production gelée le 30/09/2026.

## Contenu versionné

- application Flutter/Dart finale (lib, 	est, windows, configuration) ;
- sources natives 
ative/CrispASR ;
- sources natives 
ative/CrispEmbed ;
- 	ools/sd_server/sd_server.py final ;
- preuves légères de baseline dans docs/final-baseline ;
- résumé des actifs externes dans docs/EXTERNAL_ASSETS_SUMMARY.csv.

## Non inclus volontairement

Les éléments volumineux ou générés ne sont pas versionnés :

- modèles IA (*.gguf, *.safetensors, etc.) ;
- models/ ;
- untime/ ;
- sd_vulkan/ ;
- VoiceBake/ ;
- données utilisateur / caches RAG ;
- builds et DLL/EXE compilés.

Ils doivent être restaurés séparément sur une nouvelle machine.

## Reprise sur un autre poste

`powershell
git clone https://github.com/Dino19870/Jarvisol_V2.git
cd Jarvisol_V2
flutter pub get
flutter build windows --release
`

Les composants natifs CrispASR/CrispEmbed devront être recompilés ou restaurés
séparément selon les instructions de leurs sous-répertoires.

## Baselines importantes

- sd_server.py :
  $expectedSdHash
- CrispASR runtime de production testé : **0.8.37**
- production finale gelée d'origine :
  $Production

## Reviews connues au gel

1. **P84-DEFERRED-001** — après certaines annulations yt-dlp, un fichier
   web_audio_* peut rester sur disque.
2. **MPV REVIEW** — messages osc / Failed to create file cache observés,
   sans défaut visible de lecture pendant les tests.
3. **CrispEmbed** — présent côté runtime historique mais fournisseur non
   revalidé E2E dans la dernière campagne.

## Important

Le dépôt Git contient le code source de reprise de développement, pas une
distribution exécutable complète. Les gros modèles restent volontairement
hors Git.