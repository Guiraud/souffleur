# Souffleur

Un téléprompteur multiplateforme simple et puissant, doté du suivi vocal et de l'enregistrement vidéo intégré.

> **Note sur le projet :** Souffleur est un fork libre et open-source de [TiefPrompt](https://github.com/Tiefseetauchner/tiefprompt), développé initialement par Lena Tauchner. Souffleur enrichit l'application originale de fonctionnalités avancées telles que le défilement synchronisé sur la voix et la prévisualisation/enregistrement vidéo direct.

---

## Fonctionnalités principales

- **Suivi vocal automatique** : Le texte défile automatiquement au rythme de votre élocution (en français), avec calage précis de la ligne de lecture et surbrillance du mot lu.
- **Caméra et enregistrement vidéo** : Filmez vos prises directement depuis l'application en incrustation ou en plein écran avec le texte en transparence, puis sauvegardez-les dans la galerie de l'appareil.
- **Commandes du prompteur** : Lecture/pause, réglage fin de la vitesse (0.1x – 20x), compte à rebours personnalisable avant démarrage.
- **Miroir matériel** : Basculement miroir horizontal et vertical pour les miroirs de prompteurs physiques.
- **Mise en page & typographie** : Taille et police ajustables (y compris OpenDyslexic), alignement du texte, marge latérale et marges verticales avec dégradé d'estompage.
- **Rendu Markdown** : Prise en charge des titres, gras, italiques.
- **Personnalisation visuelle** : Thème clair, sombre ou système, couleurs d'accentuation, couleur du texte et du fond.
- **Gestion des textes** : Sauvegarde locale de multiples scripts ou mode texte rapide éphémère.
- **Raccourcis clavier personnalisables** : Contrôle intégral via clavier ou télécommande Bluetooth.
- **100 % local & respect de la vie privée** : Aucune donnée collectée, aucun traceur. Consultez notre [Politique de confidentialité](PRIVACY.md).

---

## Téléchargement

Les versions pré-compilées (APK Android et installateurs) sont disponibles dans la section [Releases](https://github.com/Guiraud/souffleur/releases).

---

## Compilation

Le script `tools/build.sh` permet de compiler facilement l'application :

```bash
Build packages.
usage: build.sh [options]

-t target   Liste des cibles séparées par des virgules :
            linux,windows,androidaab,androidapk,macos,iosapp,iosipa
-f freedom  Niveau d'application : foss ou freemium
-b dir      Répertoire de destination des paquets
-d          Build debug
-h          Afficher l'aide
```

Exemple pour compiler un APK Android en version FOSS :
```bash
./tools/build.sh -t androidapk -f foss
```

Vous pouvez également lancer directement l'application via Flutter :
```bash
flutter run
```

---

## Respect de la vie privée

Souffleur ne collecte aucune donnée personnelle et fonctionne entièrement en local sur votre appareil. Consultez le fichier [PRIVACY.md](PRIVACY.md) pour tous les détails.

---

## Licence & Remerciements

Ce projet est distribué sous licence **MIT**. Consultez le fichier [LICENSE](LICENSE) pour plus de détails.

- Basé sur **TiefPrompt** — Copyright © 2025 Lena Tauchner.
- Remerciements aux contributeurs pour les traductions :
  - Chinois : @TaoEngine
  - Russe : @Xapitonov
  - Arabe : @shadigaafar
