FROM docker.elastic.co/logstash/logstash:8.17.0

USER root

# Install git and jq (jq needed by load_all_dashboards.sh)
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends git jq curl && \
    rm -rf /var/lib/apt/lists/*

# Clone official SOF-ELK repo at latest stable public release
RUN git clone --depth=1 --branch public/v20241217 \
    https://github.com/philhagen/sof-elk.git /usr/local/sof-elk

# Install required Logstash plugins
RUN /usr/share/logstash/bin/logstash-plugin install \
    logstash-filter-tld \
    logstash-input-relp

# Remove the default pipeline config
RUN rm -f /usr/share/logstash/pipeline/logstash.conf

# Copy SOF-ELK grok patterns into Logstash's built-in patterns directory
RUN find /usr/share/logstash/vendor/bundle/jruby -name "patterns" -type d \
    -path "*/logstash-patterns-core*" \
    -exec cp /usr/local/sof-elk/grok-patterns/* {} \; 2>/dev/null || true

# Fix ownership
RUN chown -R logstash:logstash /usr/local/sof-elk /usr/share/logstash

USER logstash
