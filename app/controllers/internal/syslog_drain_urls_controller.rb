module VCAP::CloudController
  class SyslogDrainUrlsInternalController < RestController::BaseController
    # Endpoint uses mutual tls for auth, handled by nginx
    allow_unauthenticated_access

    get '/internal/v4/syslog_drain_urls', :list

    def list
      prepare_aggregate_function
      guid_to_drain_maps = AppModel.
                           join(ServiceBinding.table_name, app_guid: :guid).
                           join(Space.table_name, guid: :apps__space_guid).
                           join(Organization.table_name, id: :spaces__organization_id).
                           where(Sequel.lit('syslog_drain_url IS NOT NULL')).
                           where(Sequel.lit("syslog_drain_url != ''")).
                           group(
                             "#{AppModel.table_name}__guid".to_sym,
                             "#{AppModel.table_name}__name".to_sym,
                             "#{Space.table_name}__name".to_sym,
                             "#{Organization.table_name}__name".to_sym
                           ).
                           select(
                             "#{AppModel.table_name}__guid".to_sym,
                             "#{AppModel.table_name}__name".to_sym,
                             aggregate_function("#{ServiceBinding.table_name}__syslog_drain_url".to_sym).as(:syslog_drain_urls)
                           ).
                           select_append("#{Space.table_name}__name___space_name".to_sym).
                           select_append("#{Organization.table_name}__name___organization_name".to_sym).
                           order(:guid).
                           limit(batch_size).
                           offset(last_id).
                           all

      next_page_token = nil
      drain_urls = {}

      guid_to_drain_maps.each do |guid_and_drains|
        drain_urls[guid_and_drains[:guid]] = {
          drains: guid_and_drains[:syslog_drain_urls].split(','),
          hostname: hostname_from_app_name(guid_and_drains[:organization_name], guid_and_drains[:space_name], guid_and_drains[:name])
        }
      end

      next_page_token = last_id + batch_size unless guid_to_drain_maps.empty?

      [HTTP::OK, MultiJson.dump({ results: drain_urls, next_id: next_page_token }, pretty: true)]
    end

    get '/internal/v5/syslog_drain_urls', :listv5

    def listv5
      prepare_aggregate_function

      syslog_drain_urls_query = ServiceBinding.
                                distinct.
                                exclude(syslog_drain_url: nil).
                                exclude(syslog_drain_url: '').
                                select(:syslog_drain_url).
                                order(:syslog_drain_url).
                                limit(batch_size).
                                offset(last_id)

      bindings = ServiceBinding.
                 join(:apps, guid: :app_guid).
                 join(:spaces, guid: :apps__space_guid).
                 join(:organizations, id: :spaces__organization_id).
                 select(
                   :service_bindings__syslog_drain_url,
                   :service_bindings__credentials,
                   :service_bindings__salt,
                   :service_bindings__encryption_key_label,
                   :service_bindings__encryption_iterations,
                   :service_bindings__app_guid,
                   :apps__name___app_name,
                   :spaces__name___space_name,
                   :organizations__name___organization_name
                 ).
                 where(service_bindings__syslog_drain_url: syslog_drain_urls_query).
                   each_with_object({}) { |item, injected|
                     credentials = item.credentials
                     key = credentials.fetch('key', '')
                     cert = credentials.fetch('cert', '')
                     syslog_drain_url = item[:syslog_drain_url]
                     hostname = hostname_from_app_name(item[:organization_name], item[:space_name], item[:app_name])
                     if injected.include?(syslog_drain_url)
                       existing_item = injected[syslog_drain_url]
                       existing_cert_apps_map = existing_item[:cert_apps_map]
                       if existing_cert_apps_map.key?(cert)
                         existing_cert_entry = existing_cert_apps_map[cert]
                         existing_apps = existing_cert_entry[:apps]
                         new_apps = existing_apps.push({ hostname: hostname, app_id: item[:app_guid] })
                         existing_cert_entry[:apps] = new_apps
                       else
                         cert_apps_arr = {cert: cert, key:key, apps: [{ hostname: hostname, app_id: item[:app_guid] }]}
                         existing_cert_apps_map[cert] = cert_apps_arr
                       end
                       injected[syslog_drain_url] = existing_item
                     else
                       cert_apps_arr = {cert: cert, key:key, apps: [{ hostname: hostname, app_id: item[:app_guid] }]}
                       cert_map = {}
                       cert_map[cert] = cert_apps_arr
                       target = {
                         url: syslog_drain_url,
                         cert_apps_map: cert_map
                       }
                       injected[syslog_drain_url] = target
                     end
                     injected
                   }.values

                   bindings.each do| binding |
                   binding[:credentials] = binding[:cert_apps_map].values
                   binding.reject! { |targets| targets == :cert_apps_map }
                   end

      next_page_token = nil

      next_page_token = last_id + batch_size unless bindings.empty?

      [HTTP::OK, MultiJson.dump({ results: bindings, next_id: next_page_token }, pretty: true)]
    end

    private

    def hostname_from_app_name(*names)
      names.map { |name|
        name.gsub(/\s+/, '-').gsub(/[^-a-zA-Z0-9]+/, '').sub(/-+$/, '')[0..62]
      }.join('.')
    end

    def aggregate_function(column)
      if AppModel.db.database_type == :postgres
        Sequel.function(:string_agg, column, ',')
      elsif AppModel.db.database_type == :mysql
        Sequel.function(:group_concat, column)
      else
        raise 'Unknown database type'
      end
    end

    def prepare_aggregate_function
      if AppModel.db.database_type == :mysql
        AppModel.db.run('SET SESSION group_concat_max_len = 1000000000')
      end
    end

    def last_id
      Integer(params.fetch('next_id', 0))
    end

    def batch_size
      Integer(params.fetch('batch_size', 50))
    end
  end
end
