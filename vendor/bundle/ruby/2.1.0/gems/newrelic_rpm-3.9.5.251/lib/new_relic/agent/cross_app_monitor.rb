# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'digest'

require 'new_relic/agent/transaction_state'
require 'new_relic/agent/threading/agent_thread'

module NewRelic
  module Agent

    class CrossAppMonitor

      NEWRELIC_ID_HEADER = 'X-NewRelic-ID'
      NEWRELIC_APPDATA_HEADER = 'X-NewRelic-App-Data'
      NEWRELIC_TXN_HEADER = 'X-NewRelic-Transaction'
      NEWRELIC_TXN_HEADER_KEYS = %W{
        #{NEWRELIC_TXN_HEADER} HTTP_X_NEWRELIC_TRANSACTION X_NEWRELIC_TRANSACTION
      }
      NEWRELIC_ID_HEADER_KEYS = %W{
        #{NEWRELIC_ID_HEADER} HTTP_X_NEWRELIC_ID X_NEWRELIC_ID
      }
      CONTENT_LENGTH_HEADER_KEYS = %w{Content-Length HTTP_CONTENT_LENGTH CONTENT_LENGTH}

      attr_reader :obfuscator

      def initialize(events = nil)
        # When we're starting up for real in the agent, we get passed the events
        # Other spots can pull from the agent, during startup the agent doesn't exist yet!
        events ||= Agent.instance.events

        events.subscribe(:finished_configuring) do
          on_finished_configuring
        end
      end

      def on_finished_configuring
        setup_obfuscator
        register_event_listeners
      end

      # Expected sequence of events:
      #   :before_call will save our cross application request id to the thread
      #   :start_transaction will get called when a transaction starts up
      #   :after_call will write our response headers/metrics and clean up the thread
      def register_event_listeners
        NewRelic::Agent.logger.
          debug("Wiring up Cross Application Tracing to events after finished configuring")

        events = Agent.instance.events
        events.subscribe(:before_call) do |env| #THREAD_LOCAL_ACCESS
          if should_process_request(env)
            state = NewRelic::Agent::TransactionState.tl_get

            save_client_cross_app_id(state, env)
            save_referring_transaction_info(state, env)
            set_transaction_custom_parameters(state)
          end
        end

        events.subscribe(:after_call) do |env, (_status_code, headers, _body)| #THREAD_LOCAL_ACCESS
          state = NewRelic::Agent::TransactionState.tl_get

          insert_response_header(state, env, headers)
        end

        events.subscribe(:notice_error) do |_, options| #THREAD_LOCAL_ACCESS
          state = NewRelic::Agent::TransactionState.tl_get

          set_error_custom_parameters(state, options)
        end
      end

      # This requires :encoding_key, so must wait until :finished_configuring
      def setup_obfuscator
        @obfuscator = NewRelic::Agent::Obfuscator.new(NewRelic::Agent.config[:encoding_key])
      end

      def save_client_cross_app_id(state, request_headers)
        state.client_cross_app_id = decoded_id(request_headers)
      end

      def clear_client_cross_app_id(state)
        state.client_cross_app_id = nil
      end

      def save_referring_transaction_info(state, request_headers)
        txn_header = from_headers(request_headers, NEWRELIC_TXN_HEADER_KEYS) or return
        txn_header = obfuscator.deobfuscate(txn_header)
        txn_info = NewRelic::JSONWrapper.load(txn_header)
        NewRelic::Agent.logger.debug("Referring txn_info: %p" % [txn_info])

        state.referring_transaction_info = txn_info
      end

      def client_referring_transaction_guid(state)
        info = state.referring_transaction_info or return nil
        return info[0]
      end

      def client_referring_transaction_record_flag(state)
        info = state.referring_transaction_info or return nil
        return info[1]
      end

      def client_referring_transaction_trip_id(state)
        info = state.referring_transaction_info or return nil
        return info[2]
      end

      def client_referring_transaction_path_hash(state)
        info = state.referring_transaction_info or return nil
        return info[3].is_a?(String) && info[3]
      end

      def insert_response_header(state, request_headers, response_headers)
        unless state.client_cross_app_id.nil?
          txn = state.current_transaction
          unless txn.nil?
            txn.freeze_name_and_execute_if_not_ignored do
              timings = state.timings
              content_length = content_length_from_request(request_headers)

              set_response_headers(state, response_headers, timings, content_length)
              set_metrics(state.client_cross_app_id, timings)
            end
          end
          clear_client_cross_app_id(state)
        end
      end

      def should_process_request(request_headers)
        return cross_app_enabled? && trusts?(request_headers)
      end

      def cross_app_enabled?
        NewRelic::Agent::CrossAppTracing.cross_app_enabled?
      end

      # Expects an ID of format "12#345", and will only accept that!
      def trusts?(request)
        id = decoded_id(request)
        split_id = id.match(/(\d+)#\d+/)
        return false if split_id.nil?

        NewRelic::Agent.config[:trusted_account_ids].include?(split_id.captures.first.to_i)
      end

      def set_response_headers(state, response_headers, timings, content_length)
        response_headers[NEWRELIC_APPDATA_HEADER] = build_payload(state, timings, content_length)
      end

      def build_payload(state, timings, content_length)
        payload = [
          NewRelic::Agent.config[:cross_process_id],
          timings.transaction_name,
          timings.queue_time_in_seconds.to_f,
          timings.app_time_in_seconds.to_f,
          content_length,
          state.request_guid
        ]
        payload = obfuscator.obfuscate(NewRelic::JSONWrapper.dump(payload))
      end

      def set_transaction_custom_parameters(state)
        # We expect to get the before call to set the id (if we have it) before
        # this, and then write our custom parameter when the transaction starts
        NewRelic::Agent.add_custom_parameters(:client_cross_process_id => state.client_cross_app_id) if state.client_cross_app_id

        referring_guid = client_referring_transaction_guid(state)
        if referring_guid
          NewRelic::Agent.logger.debug "Referring transaction guid: %p" % [referring_guid]
          NewRelic::Agent.add_custom_parameters(:referring_transaction_guid => referring_guid)
        end
      end

      def set_error_custom_parameters(state, options)
        options[:client_cross_process_id] = state.client_cross_app_id if state.client_cross_app_id
      end

      def set_metrics(id, timings)
        metric_name = "ClientApplication/#{id}/all"
        NewRelic::Agent.record_metric(metric_name, timings.app_time_in_seconds)
      end

      def decoded_id(request)
        encoded_id = from_headers(request, NEWRELIC_ID_HEADER_KEYS)
        return "" if encoded_id.nil?

        obfuscator.deobfuscate(encoded_id)
      end

      def content_length_from_request(request)
        from_headers(request, CONTENT_LENGTH_HEADER_KEYS) || -1
      end

      def hash_transaction_name(identifier)
        Digest::MD5.digest(identifier).unpack("@12N").first & 0xffffffff
      end

      def path_hash(txn_name, seed)
        rotated    = ((seed << 1) | (seed >> 31)) & 0xffffffff
        app_name   = NewRelic::Agent.config.app_names.first
        identifier = "#{app_name};#{txn_name}"
        sprintf("%08x", rotated ^ hash_transaction_name(identifier))
      end

      private

      def from_headers(request, try_keys)
        # For lookups, upcase all our keys on both sides just to be safe
        upcased_keys = try_keys.map{|k| k.upcase}
        upcased_keys.each do |header|
          found_key = request.keys.find { |k| k.upcase == header }
          return request[found_key] unless found_key.nil?
        end
        nil
      end

    end

  end
end
