# frozen_string_literal: true
# The file needs to have the name filter_<type> to be auto-discoverable by fluentd

require 'fluent/env'
require 'fluent/plugin/filter'
require 'set'
require 'json'
require 'uri'
require 'net/http'

module Fluent::Plugin
  class KubeletMetadata < Fluent::Plugin::Filter
    Fluent::Plugin.register_filter('kubelet_metadata', self)

    config_param :statsd, :string, default: nil

    KUBELET_ERROR_BACKOFF_SECONDS = [0.1, 0.5, 1].freeze
    KUBELET_MAX_REQUESTS_PER_SECOND = 10
    POD_CACHE_SIZE = 200 # assuming users run 10-100 pods per node

    # rubocop:disable Layout/LineLength
    # from https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter/blob/8f95b0e5fda922ef0576c7ce53d0c72f19a86754/lib/fluent/plugin/filter_kubernetes_metadata.rb#L52
    # for example: input.kubernetes.pod.var.log.containers.fluentd-mgj9v_default_vault-pki-auth-manager-26f3a7bad715d9d324fb3c818681ec01df14831f0585cb83f2df25a7386ee5f4.log
    TAG_REGEX = Regexp.compile('var\.log\.containers\.(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log$')
    # rubocop:enable Layout/LineLength

    # - no operations on all values to be fast
    # - cannot store nil as value
    class ThreadsafeLruCache
      def initialize(size)
        @size = size
        @data = {}
        @mutex = Mutex.new
      end

      def [](key)
        @mutex.synchronize do
          value = @data.delete(key) # always remove ... later add it back if necessary
          return if value.nil? # miss
          @data[key] = value # mark as recently used
        end
      end

      def []=(key, value)
        @mutex.synchronize do
          @data.delete @data.first[0] if @data.size == @size # make room
          @data[key] = value
        end
      end
    end

    def initialize
      super
      @cache = ThreadsafeLruCache.new(POD_CACHE_SIZE)
      @throttle_mutex = Mutex.new
    end

    def configure(conf)
      super
      @statsd = Object.const_get(@statsd) if @statsd
      fill_cache unless ARGV.include?('--dry-run')
    end

    def filter(tag, _time, record)
      return record unless match = tag.match(TAG_REGEX)&.named_captures

      labels = pod_labels(
        [match.fetch('namespace'), match.fetch('pod_name')],
        tags: [
          "pod_name:#{match.fetch('pod_name')}",
          "namespace:#{match.fetch('namespace')}",
          "container:#{match.fetch('container_name')}"
        ]
      )

      record.merge(
        'docker' => { 'container_id' => match.fetch('docker_id') },
        'kubernetes' => {
          'container_name' => match.fetch('container_name'),
          'namespace_name' => match.fetch('namespace'),
          'pod_name' => match.fetch('pod_name'),
          'labels' => labels
        }
      )
    end

    private

    def pod_labels(key, **args)
      @cache[key] || begin
        inc "soft_miss"
        fill_cache
        @cache[key] || begin
          inc "hard_miss", **args # need tags here to be able to debug
          {}
        end
      end
    end

    # stores each pods labels that kubelet knows in the cache
    # only storing the labels since pod objects are big
    def fill_cache
      pods.each do |pod|
        @cache[[pod.dig("metadata", "namespace"), pod.dig("metadata", "name")]] = pod.dig("metadata", "labels") || {}
      end
    end

    # /runningpods/ has much less data, but does not include initContainerStatuses
    #
    # InitContainers are often not available when logs start coming in
    #
    # Full kubelet api see https://stackoverflow.com/questions/35075195/is-there-api-documentation-for-kubelet-api
    def pods
      retry_on_error backoff: KUBELET_ERROR_BACKOFF_SECONDS do
        throttle per_second: KUBELET_MAX_REQUESTS_PER_SECOND, throttled: [] do
          JSON.parse(http_get('https://localhost:10250/pods')).fetch("items")
        end
      end
    rescue StandardError
      []
    end

    def http_get(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = 2
      http.read_timeout = 5

      request = Net::HTTP::Get.new(uri.request_uri)
      request['Authorization'] = "Bearer #{File.read("/var/run/secrets/kubernetes.io/serviceaccount/token")}"

      response = http.start { http.request request }

      raise "Error response #{response.code} -- #{response.body}" unless response.code == "200"

      response.body
    end

    def throttle(per_second:, throttled:)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i
      c = nil

      @throttle_mutex.synchronize do
        old_t, c = @throttle
        old_t == t ? c += 1 : c = 1
        @throttle = [t, c]
      end

      if c > per_second
        inc "throttled"
        throttled
      else
        yield
      end
    end

    def retry_on_error(backoff:)
      yield
    rescue StandardError
      backoff_index ||= -1
      backoff_index += 1
      inc "kubelet_error", tags: ["error:#{$!.class}"]
      raise unless delay = backoff[backoff_index]

      sleep delay
      retry
    end

    def inc(metric, **args)
      @statsd&.increment "fluentd.kubelet_metadata.#{metric}", **args
    end
  end
end
