# Quietbar — `make install` é o único comando necessário no dia a dia.
APP_NAME := Quietbar
DEST     := /Applications/$(APP_NAME).app
DEV_DD   := .build/xcode-debug

.DEFAULT_GOAL := help
.PHONY: help install dev test release notarize press-kit

help: ## Lista os alvos
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-8s %s\n", $$1, $$2}'

install: ## Compila em Release, assina, instala em /Applications, ativa abrir no login e abre o app
	scripts/build-app.sh
	@pkill -x $(APP_NAME) 2>/dev/null; \
	 for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.5; done; \
	 pkill -9 -x $(APP_NAME) 2>/dev/null; true
	rm -rf "$(DEST)"
	ditto dist/$(APP_NAME).app "$(DEST)"
	open "$(DEST)" --args --register-login-item
	@echo "Instalado em $(DEST). Abra as Configurações pelo ícone de fone na barra de menus."

dev: ## Compila em Debug e roda o app no terminal (logs aqui; Ctrl-C para sair)
	@command -v xcodegen >/dev/null && xcodegen generate --quiet || true
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Debug \
	  -derivedDataPath $(DEV_DD) build -quiet
	@pkill -x $(APP_NAME) 2>/dev/null; true
	$(DEV_DD)/Build/Products/Debug/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)

test: ## Roda todos os testes (MDRKit, MDRSession, HeadphoneModel)
	swift test

release: ## Build Release universal e .dmg em dist/ (Developer ID com QUIETBAR_SIGN_IDENTITY; senão, ad-hoc)
	scripts/release.sh

notarize: ## Notariza e grampeia o .app e o .dmg (exige QUIETBAR_SIGN_IDENTITY e QUIETBAR_NOTARY_PROFILE)
	scripts/notarize.sh

press-kit: ## Gera as imagens de docs/screenshots e o GIF de docs/media em janelas próprias do app
	scripts/press-kit.sh
