# Reprendre le développement sur un autre poste

## 1. Cloner

```powershell
git clone https://github.com/Dino19870/Jarvisol_V2.git
cd Jarvisol_V2
```

## 2. Installer Flutter/Dart

Utiliser une version Flutter compatible avec le `pubspec.lock` du dépôt, puis :

```powershell
flutter doctor
flutter pub get
```

## 3. Composants natifs

Les sources sont sous :

```text
native\CrispASR
native\CrispEmbed
```

Recompiler les DLL selon leur configuration de build ou restaurer les binaires
validés depuis une archive séparée.

## 4. Actifs lourds

Les modèles et runtimes ne sont PAS dans Git.

Consulter :

```text
docs\EXTERNAL_ASSETS_SUMMARY.csv
```

Les emplacements attendus dans une distribution portable restent notamment :

```text
models\
runtime\
sd_vulkan\
VoiceBake\
```

## 5. Serveur image

Source finale :

```text
tools\sd_server\sd_server.py
```

La construction de `sd_server.exe` doit rester séparée du dépôt Git des modèles.

## 6. Vérifier avant un nouveau développement

Les CSV de :

```text
docs\final-baseline\
```

documentent la baseline finale gelée. Toute modification fonctionnelle future
doit repartir d'une branche Git dédiée et être revalidée avant remplacement
de la production.