# Security scan allowlist

Le dépôt a été scanné avant sa première publication publique.

Six détections sont classées comme **fixtures de test / démonstration / documentation** :

- trois clés privées C2PA de démonstration ou certificat par défaut dans CrispASR ;
- une clé privée d'exemple dans la documentation CrispEmbed ;
- deux chaînes au format sk-... dans des tests Dart.

Aucune de ces détections n'est utilisée comme credential de production.

Règle de sécurité du script de publication :
**toute détection supplémentaire hors de cette liste exacte bloque le push.**

Les valeurs de clés elles-mêmes ne sont volontairement pas reproduites dans ce document.