sudo apt update
sudo apt install zlib1g-dev libpq-dev

curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

git clone https://github.com/hasura/graphql-engine.git
. /home/ubuntu/.ghcup/env

mkdir ~/bin
(cd graphql-engine/server; \
  cabal new-build; \
  cp $(cabal new-exec which graphql-engine) ~/bin \
  )
