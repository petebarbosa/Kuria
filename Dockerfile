# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=4.0.9
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages (keep update/install/cleanup in one layer so the
# package lists are never persisted in the final image)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libvips postgresql-client libyaml-0-2 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ARG BUILD_COMMIT_SHA
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    BUILD_COMMIT_SHA=${BUILD_COMMIT_SHA}
    
# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems (base stage no longer ships apt lists)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential libpq-dev git pkg-config libyaml-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle config set --local frozen false && \
    bundle lock --add-platform x86_64-linux && \
    bundle install

RUN rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Copy application code
COPY . .

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
# RAILS_GROUPS=build loads the build-only Tailwind gem so its tasks run here and
# not at runtime.
RUN SECRET_KEY_BASE_DUMMY=1 RAILS_GROUPS=build ./bin/rails assets:precompile

# Drop build-only gems (Tailwind) from the bundle that ships in the final image
RUN BUNDLE_WITHOUT="development:test:build" bundle clean --force

# Remove non-runtime artifacts: Stripe's RBI type signatures, Lucide's source
# SVGs, and the Bootsnap cache produced by asset compilation. Stripe loads only
# lib/, Lucide's default :memory provider reads icons/stripped.bin.gz, and
# Bootsnap stays enabled and recreates its cache in tmp/cache on first boot.
# Regenerating RBI files or icons is intentionally not available at runtime.
RUN rm -rf "${BUNDLE_PATH}"/ruby/*/gems/stripe-*/rbi \
           "${BUNDLE_PATH}"/ruby/*/bundler/gems/lucide-rails-*/icons/original \
           "${BUNDLE_PATH}"/ruby/*/bundler/gems/lucide-rails-*/icons/stripped \
           /rails/tmp/cache/bootsnap

# Final stage for app image
FROM base

# Build-only gems are not present in the runtime bundle
ENV BUNDLE_WITHOUT="development:test:build"

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

# Copy built artifacts: gems, application
# App files are chowned during COPY so no recursive chown layer is needed.
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=1000:1000 --from=build /rails /rails

USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
