# frozen_string_literal: true
require_relative "../../test_helper"

SingleCov.covered!

describe Fluent::Plugin::KubeletMetadata do
  def expect_sleep(times)
    Fluent::Plugin::KubeletMetadata.any_instance.unstub(:sleep)
    Fluent::Plugin::KubeletMetadata.any_instance.expects(:sleep).times(times)
  end

  def freeze_time
    Process.stubs(:clock_gettime).returns(123.123)
  end

  let(:config) { +"" }
  let(:filter) do
    filter = Fluent::Plugin::KubeletMetadata.new
    filter.stubs(:event_emitter_router)
    filter.configure Fluent::Config.parse(config, "(test)", "(test_dir)")
    filter
  end
  let(:container_id) { "49095a2894da899d3b327c5fde1e056a81376cc9a8f8b09a195f2a92bceed459" }
  let(:tag) { +"var.log.containers.my-app-98rqc_my-namespace_main-#{container_id}.log" }
  let(:replies) { [{ body: { items: pods }.to_json }] }
  let(:pods) { [] }
  let(:pod) do
    {
      metadata: { name: "my-app-98rqc", namespace: "my-namespace", labels: { la: "bel" } },
      status: { containerStatuses: [{ containerID: "docker://#{container_id}" }] }
    }
  end

  before do
    File.stubs(:read).with("/var/run/secrets/kubernetes.io/serviceaccount/token").returns("TOKEN")
    Fluent::Plugin::KubeletMetadata.any_instance.expects(:sleep).with { raise "sleep" }.never
  end

  describe "#filter" do
    def call(*tags)
      @fetch = stub_request(:get, "https://localhost:10250/pods").to_return(*replies)
      tags.map { |tag| filter.filter(tag, nil, { "foo" => "bar" }) }.first
    end

    it "leaves non-kubernetes requests alone" do
      assert tag.tr!("_", "-")
      call(tag).must_equal("foo" => "bar")
      assert_requested @fetch, times: 1
    end

    it "adds basic info when pod cannot be found" do
      call(tag).must_equal(
        "foo" => "bar",
        "docker" => { "container_id" => container_id },
        "kubernetes" => {
          "container_name" => "main", "namespace_name" => "my-namespace", "pod_name" => "my-app-98rqc", "labels" => {}
        }
      )
      assert_requested @fetch, times: 2
    end

    it 'adds pod labels' do
      pods << pod
      call(tag).must_equal(
        "foo" => "bar",
        "docker" => { "container_id" => container_id },
        "kubernetes" => {
          "container_name" => "main", "namespace_name" => "my-namespace", "pod_name" => "my-app-98rqc",
          "labels" => { "la" => "bel" }
        }
      )
      assert_requested @fetch, times: 1
    end

    it "can send stats" do
      config.replace("statsd TestStats")
      TestStats.expects(:increment).times(2)
      call(tag)
    end

    it 'refreshes the cache on missing pods' do
      replies.push(body: { items: [pod] }.to_json)
      call(tag).must_equal(
        "foo" => "bar",
        "docker" => { "container_id" => container_id },
        "kubernetes" => {
          "container_name" => "main", "namespace_name" => "my-namespace", "pod_name" => "my-app-98rqc",
          "labels" => { "la" => "bel" }
        }
      )
      assert_requested @fetch, times: 2
    end

    it 'caches missing labels' do
      pod[:metadata].delete :labels
      pods << pod
      call(tag).must_equal(
        "foo" => "bar",
        "docker" => { "container_id" => container_id },
        "kubernetes" => {
          "container_name" => "main", "namespace_name" => "my-namespace", "pod_name" => "my-app-98rqc", "labels" => {}
        }
      )
      assert_requested @fetch, times: 1
    end

    it 'cannot fetch when throttled' do
      freeze_time
      call(*Array.new(11) { tag.sub(container_id, SecureRandom.hex(32)) }).dig("kubernetes", "labels").must_equal({})
      assert_requested @fetch, times: 10
    end

    it "does not fetch when in dry-run" do
      ARGV.push '--dry-run'
      filter
    ensure
      ARGV.pop
    end

    it "retries on error and succeeds" do
      expect_sleep 2
      replies.replace([{ body: "WHOOPS" }, { body: "WHOOPS" }, { body: { items: [pod] }.to_json }])
      call(tag).dig("kubernetes", "labels").must_equal("la" => "bel")
      assert_requested @fetch, times: 3
    end

    it "fails on persistent internal error" do
      expect_sleep 6
      replies[0][:body] = "WHOOPS"
      call(tag).dig("kubernetes", "labels").must_equal({})
      assert_requested @fetch, times: 8 # 4 from initialize and 4 from fetch
    end

    it "fails on persistent status error" do
      expect_sleep 6
      replies[0][:status] = 500
      call(tag).dig("kubernetes", "labels").must_equal({})
      assert_requested @fetch, times: 8 # 4 from initialize and 4 from fetch
    end

    it "throttles retries" do
      expect_sleep 8
      freeze_time
      replies.replace([{ body: "WHOOPS" }])
      call(*Array.new(7) { tag.sub(container_id, SecureRandom.hex(32)) }).dig("kubernetes", "labels").must_equal({})
      assert_requested @fetch, times: 10
    end
  end

  describe Fluent::Plugin::KubeletMetadata::ThreadsafeLruCache do
    let(:cache) { Fluent::Plugin::KubeletMetadata::ThreadsafeLruCache.new(2) }

    it "expires old items" do
      cache[1] = :a
      cache[2] = :b
      cache[3] = :c
      cache[1].must_be_nil
      cache[2].must_equal :b
      cache[3].must_equal :c
    end

    it "refreshes expiry with get" do
      cache[1] = :a
      cache[2] = :b
      cache[1] # refresh
      cache[3] = :c
      cache[1].must_equal :a
      cache[2].must_be_nil
      cache[3].must_equal :c
    end
  end
end
