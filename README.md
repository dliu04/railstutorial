# Ruby on Rails Tutorial Repo

This repository follows along with the Ruby on Rails Tutorial.

## Repo layout

- `hello_app/` is the Rails application.
- More to come later.
- The top level folder exists to hold the tutorial notes and the app together in one repository.

## Getting started

Install Ruby first. This app uses Ruby 4.0.6.

If you are on macOS, one simple option is `rbenv`:

```bash
brew install rbenv ruby-build
rbenv install 4.0.6
rbenv local 4.0.6
```

Ruby ships with `gem`, which is the Ruby package manager. After Ruby is installed, use `gem` to install Bundler:

```bash
gem install bundler
```

Then move into the Rails app and install the dependencies listed in its `Gemfile`:

```bash
cd hello_app
bundle install
```

After the gems are installed, set up the app:

```bash
bin/setup --skip-server
```

Start the development server with:

```bash
bin/dev
```

The detailed setup instructions live in [hello_app/README.md](/Users/dylanliu/code/railstutorial/hello_app/README.md).

## What Git ignores on purpose

Some files are intentionally not committed because each developer should generate or manage them locally.

- `.env*` files are ignored. Create your own environment files locally if you add custom environment variables.
- `config/*.key` is ignored. If your app uses encrypted credentials, each developer needs their own key file or a securely shared one.
- `log/` and `tmp/` contents are ignored except for placeholder files. Rails recreates these as needed.
- `storage/` contents are ignored except for placeholder files. This includes uploaded files and local SQLite database files.
- `.bundle/` is ignored. Bundler creates this locally.
- `public/assets` is ignored because compiled assets are build output.

## Before you commit tutorial work

- Run Git commands from the repository root unless you intentionally create a separate repo.
- Do not expect ignored files such as local databases, logs, temp files, or key files to appear in Git status.
- If the tutorial tells you to create secrets or environment specific configuration, set those up locally even though they will not be committed.
