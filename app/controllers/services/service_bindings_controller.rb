require 'services/api'

module VCAP::CloudController
  class ServiceBindingsController < RestController::ModelController
    define_attributes do
      to_one    :app
      to_one    :service_instance
      attribute :binding_options, Hash, :default => {}
    end

    get path,      :enumerate
    get path_guid, :read

    query_parameters :app_guid, :service_instance_guid

    def self.dependencies
      [ :services_event_repository ]
    end

    def inject_dependencies(dependencies)
      super
      @services_event_repository = dependencies.fetch(:services_event_repository)
    end

    post path, :create
    def create
      json_msg = self.class::CreateMessage.decode(body)

      @request_attrs = json_msg.extract(:stringify_keys => true)

      logger.debug "cc.create", :model => self.class.model_class_name,
        :attributes => request_attrs

      raise InvalidRequest unless request_attrs

      instance_guid = request_attrs['service_instance_guid']
      app_guid      = request_attrs['app_guid']

      validate_service_instance(instance_guid)
      validate_app(app_guid)

      service_binding = ServiceBinding.new(@request_attrs)
      validate_access(:create, service_binding)

      if service_binding.valid?
        service_binding.bind!
      else
        raise Sequel::ValidationFailed.new(service_binding)
      end

      @services_event_repository.record_service_binding_event(:create, service_binding)

      [ HTTP::CREATED,
        { "Location" => "#{self.class.path}/#{service_binding.guid}" },
        object_renderer.render_json(self.class, service_binding, @opts)
      ]
    end

    delete path_guid, :delete
    def delete(guid)
      service_binding = ServiceBinding.find(guid: guid)
      raise_if_has_associations!(service_binding) if v2_api? && !recursive?

      deletion_job = Jobs::Runtime::ModelDeletion.new(ServiceBinding, guid)
      delete_and_audit_job = Jobs::AuditEventJob.new(deletion_job, @services_event_repository, :record_service_binding_event, :delete, service_binding)

      if async?
        job = Jobs::Enqueuer.new(delete_and_audit_job, queue: "cc-generic").enqueue()
        [HTTP::ACCEPTED, JobPresenter.new(job).to_json]
      else
        delete_and_audit_job.perform
        [HTTP::NO_CONTENT, nil]
      end
    end

    private

    def validate_app(app_guid)
      app = App.find(guid: app_guid)
      raise VCAP::Errors::ApiError.new_from_details('AppNotFound', guid: app_guid) unless app
    end

    def validate_service_instance(instance_guid)
      service_instance = ServiceInstance.find(guid: instance_guid)

      raise VCAP::Errors::ApiError.new_from_details('ServiceInstanceNotFound', guid: instance_guid) unless service_instance
      raise VCAP::Errors::ApiError.new_from_details('UnbindableService') unless service_instance.bindable?
    end

    def self.translate_validation_exception(e, attributes)
      unique_errors = e.errors.on([:app_id, :service_instance_id])
      if unique_errors && unique_errors.include?(:unique)
        Errors::ApiError.new_from_details("ServiceBindingAppServiceTaken", string: "#{attributes["app_guid"]} #{attributes["service_instance_guid"]}")
      elsif e.errors.on(:app) && e.errors.on(:app).include?(:presence)
        Errors::ApiError.new_from_details('AppNotFound', guid: attributes['app_guid'])
      elsif e.errors.on(:service_instance) && e.errors.on(:service_instance).include?(:presence)
        Errors::ApiError.new_from_details('ServiceInstanceNotFound', guid: attributes['service_instance_guid'])
      else
        Errors::ApiError.new_from_details("ServiceBindingInvalid", string: e.errors.full_messages)
      end
    end

    define_messages
  end
end
