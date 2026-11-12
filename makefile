# =============================================================================
# Makefile - Borne Multiservices (shadowClone / e-Broyeur / VirtuPack / Bastion-Antiviral)
# =============================================================================

SCRIPT_ISO   := forgeIsoMenu64.sh
BUILD_DIR    := ./debian-live-build
REPOS_DIR    := ./repos-src
ISO_FILE     := borne-multiservices-v1.0.iso

# Utilise sudo automatiquement si on n'est pas déjà root
SUDO := $(if $(filter 0,$(shell id -u)),,sudo)

.PHONY: all clean distclean help

# Cible par défaut : clone les 4 dépôts et construit l'ISO.
all:
	chmod +x $(SCRIPT_ISO) && $(SUDO) bash $(SCRIPT_ISO)

# Supprime le répertoire de travail live-build et les dépôts clonés,
# conserve l'ISO déjà générée.
clean:
	$(SUDO) rm -rf $(BUILD_DIR) $(REPOS_DIR)

# Comme clean, mais supprime aussi l'ISO générée.
distclean: clean
	$(SUDO) rm -f $(ISO_FILE)

help:
	@echo "Cibles disponibles :"
	@echo "  make all       - Clone les 4 depots et construit l'ISO"
	@echo "  make clean     - Supprime le repertoire de build et les depots clones"
	@echo "  make distclean - clean + supprime aussi l'ISO generee"

# Catch-all pour les commandes invalides
.DEFAULT:
	@echo "Commande invalide : '$@'"
	@echo ""
	@$(MAKE) help
	@false
