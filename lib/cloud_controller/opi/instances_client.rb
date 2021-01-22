require 'retryable'
require 'httpclient'
require 'json'
require 'cloud_controller/errors/instances_unavailable'
require 'cloud_controller/errors/no_running_instances'
require 'cloud_controller/opi/base_client'

module OPI
  class InstancesClient < BaseClient
    class Error < StandardError; end

    LRP_INSTANCES_RETRIES = 5
    ActualLRPKey = Struct.new(:index, :process_guid)
    ActualLRPNetInfo = Struct.new(:address, :ports)
    PortMapping = Struct.new(:container_port, :host_port)
    DesiredLRP = Struct.new(:PlacementTags, :metric_tags)

    class ActualLRPNetInfo
      def to_hash
        to_h
      end
    end

    class ActualLRP
      attr_reader :actual_lrp_key, :state, :since, :placement_error, :actual_lrp_net_info

      def initialize(instance, process_guid)
        @actual_lrp_key = ActualLRPKey.new(instance['index'], process_guid)
        @state = instance['state']
        @since = instance['since']
        @placement_error = instance['placement_error']
        @actual_lrp_net_info = ActualLRPNetInfo.new('127.0.0.1', Array[PortMapping.new(8080, 80)])
      end

      def ==(other)
        other.class == self.class && other.actual_lrp_key == @actual_lrp_key
      end
    end

    def lrp_instances(process)
      return confirm_stopped(process) if process.stopped?

      parsed_response = get_instances(process)
      parsed_response['instances'].map do |instance|
        ActualLRP.new(instance, parsed_response['process_guid'])
      end
    end

    # Currently opi does not support isolation segments. This stub is necessary
    # because cc relies that at least one placement tag will be available
    def desired_lrp_instance(process)
      DesiredLRP.new(['placeholder'], { "process_id": 0 })
    end

    private

    def confirm_stopped(process)
      parsed_response = JSON.parse(client.get(instances_path(process)).body)
      raise Error.new("expected no instances for stopped process: #{parsed_response['error']}") unless parsed_response['error'].include?('not found')

      []
    end

    def get_instances(process)
      Retryable.retryable(sleep: exponential_backoff_from_500ms, tries: LRP_INSTANCES_RETRIES, log_method: log_method) do
        parsed_response = JSON.parse(client.get(instances_path(process)).body)
        raise_error(parsed_response)
        return parsed_response
      end
    end

    def instances_path(process)
      "/apps/#{process.guid}/#{process.version}/instances"
    end

    def exponential_backoff_from_500ms
      lambda { |try| 2**(try - 2) }
    end

    def log_method
      lambda do |retries, exception|
        if retries.zero?
          logger.error("Failed to fetch instances after #{LRP_INSTANCES_RETRIES} retries, giving up. exception: #{exception}")
        else
          logger.info("Failed fetching lrp instances, retrying. exception: #{exception}")
        end
      end
    end

    def raise_error(parsed_response)
      raise Error.new(parsed_response['error']) if parsed_response['error']
    end

    def logger
      Steno.logger('opi.instances_client')
    end
  end
end
