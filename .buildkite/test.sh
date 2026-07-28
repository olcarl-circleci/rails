#!/usr/bin/env bash
set -euo pipefail

# Buildkite equivalent of .circleci/config.yml's `test` job, run on the selfhosted0
# Elastic CI Stack agents (Amazon Linux 2023). Checkout is implicit in Buildkite.
#
# ponytail: agents scale to zero, so gems+ruby are cached in S3 keyed on Gemfile.lock
# instead of CircleCI's restore_cache/save_cache. Plain aws-cli + tar, no cache plugin.
# ponytail: caching is best-effort; a restore/save failure never fails the build.

RUBY_VERSION=3.4
CACHE_BUCKET="${CACHE_BUCKET:?set CACHE_BUCKET in .buildkite/pipeline.yml}"

# Keep gems and ruby inside the checkout so one tarball round-trips the whole cache.
export BUNDLE_PATH="$PWD/vendor/bundle"
export MISE_DATA_DIR="$PWD/.mise-data"

lock_sum=$(sha256sum Gemfile.lock | cut -d' ' -f1)
cache_key="rails/bundle-mise-ruby${RUBY_VERSION}-${lock_sum}.tgz"
cache_uri="s3://${CACHE_BUCKET}/${cache_key}"

echo "--- :package: restore cache ($cache_key)"
if aws s3 cp "$cache_uri" - 2>/dev/null | tar xz 2>/dev/null; then
  echo "cache hit"
else
  echo "cache miss"
fi

echo "--- :arrow_down: install mise"
command -v mise >/dev/null || curl -fsSL https://mise.run | sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash --shims)"

echo "--- :wrench: build toolchain"
# ponytail: the custom agent AMI ships cc + libxml2-devel (baked via
# .buildkite/ami/buildkite-libxml2.pkr.hcl), so every native gem incl. libxml-ruby
# builds with nothing to install here. Fail clearly if a future AMI drops the compiler.
command -v cc >/dev/null || { echo "no C compiler on agent; rebake the AMI (.buildkite/ami/)"; exit 1; }

echo "--- :ruby: install ruby ${RUBY_VERSION}"
mise use -g "ruby@${RUBY_VERSION}"
ruby -v

echo "--- :bundler: install gems"
gem install bundler
mise reshim
bundle install --jobs 4 --retry 3

echo "--- :arrow_up: save cache"
# ponytail: immutable key — upload once per Gemfile.lock + ruby combo, best-effort.
if aws s3api head-object --bucket "$CACHE_BUCKET" --key "$cache_key" >/dev/null 2>&1; then
  echo "cache already present, skip upload"
else
  { tar cz vendor/bundle .mise-data | aws s3 cp - "$cache_uri" && echo "cache saved"; } \
    || echo "cache save failed (non-fatal)"
fi

echo "--- :test_tube: unit tests"
for f in activesupport activemodel actionmailer actionview actionpack; do
  (cd "$f" && bundle exec rake test)
done
# ponytail: activejob's default task fans out over 6 queue adapters —
# resque/sneakers/backburner/queue_classic need redis/rabbitmq/beanstalkd/pg.
# These three run in-process. Add services if you need adapter coverage.
(cd activejob && bundle exec rake test:test test:async test:inline)
