# Changelog

Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/), versions en [SemVer](https://semver.org/lang/fr/).

## [1.2.0] - 2026-11-13

### Ajouté

- Barre de menus configurable : jusqu'à 3 valeurs au choix (CPU, RAM, disque libre, débit ↓/↑, batterie), en format compact. Réglage dans le panneau.

## [1.1.0] - 2026-11-13

### Ajouté

- **Smart Clean** : nettoyage en un clic des catégories sans risque (caches d'apps, développeur, navigateurs, journaux), avec confirmation. Tableau de bord et barre de menus.
- Version de l'app affichée dans la barre latérale et le panneau de la barre de menus.

### Modifié

- Fenêtre fermée : l'icône disparaît du Dock, le service reste dans la barre de menus.
- Cmd+Q et « Quitter » du Dock ne ferment plus que la fenêtre. Arrêt complet : **Quitter** dans le panneau de la barre de menus. La fermeture de session n'est pas bloquée.
- `scripts/build-app.sh` lit la version dans le dernier tag git (`VERSION=x.y.z` pour forcer).

## [1.0.0] - 2026-11-13

Première version publique.

### Ajouté

- **Tableau de bord** : jauge disque, Smart Scan, plus gros dossiers.
- **Santé du Mac** : score sur 100 et KPI (batterie, SMART du SSD, espace, mémoire, swap, charge, chauffe, uptime).
- **Space Lens** : carte treemap navigable, analyse du dossier personnel, du disque entier ou d'un dossier choisi.
- **Nettoyage** : caches d'apps, caches développeur, caches profonds des navigateurs, journaux, modèles IA, Corbeille.
- **Gros fichiers** : filtres par taille et âge, détection de doublons par SHA-256.
- **Désinstalleur** : app et fichiers résiduels de `~/Library`.
- **Performance** : mémoire, processeur, réseau, apps les plus gourmandes, agents de démarrage.
- **Journaux** : journal intégré avec filtre par niveau, recherche, copie, fichier rotatif.
- **Barre de menus** : panneau rapide, service permanent, lancement à l'ouverture de session, alerte sous 10 Go libres.
- Logo, icône d'app et écran de démarrage.
- `cmfm-cli` : moteur en ligne de commande, lecture seule.
- Garde-fou `SafeRemover` pour toutes les suppressions, Corbeille par défaut.
- Pipeline de tests GitHub Actions.

[1.2.0]: https://github.com/DamienGdn/cleanMyFuckingMac/releases/tag/v1.2.0
[1.1.0]: https://github.com/DamienGdn/cleanMyFuckingMac/releases/tag/v1.1.0
[1.0.0]: https://github.com/DamienGdn/cleanMyFuckingMac/releases/tag/v1.0.0
