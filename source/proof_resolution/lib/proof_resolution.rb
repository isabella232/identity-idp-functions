require 'bundler/setup' if !defined?(Bundler)
require 'faraday'
require 'json'
require 'retries'
require 'proofer'
require 'aamva'
require 'lexisnexis'
require '/opt/ruby/lib/ssm_helper' if !defined?(IdentityIdpFunctions::SsmHelper)

module IdentityIdpFunctions
  class ProofResolution
    def self.handle(event:, context:, &callback_block)
      params = JSON.parse(event.to_json, symbolize_names: true)
      new(**params).proof(&callback_block)
    end

    attr_reader :applicant_pii, :callback_url, :should_proof_state_id

    def initialize(applicant_pii:, callback_url:, should_proof_state_id:)
      @applicant_pii = applicant_pii
      @callback_url = callback_url
      @should_proof_state_id = should_proof_state_id
    end

    def proof(&callback_block)
      set_up_env!

      proofer_result = with_retries(**retry_options) do
        lexisnexis_proofer.proof(applicant_pii)
      end

      result = proofer_result.to_h

      result[:context] = { stages: [resolution: LexisNexis::InstantVerify::Proofer.vendor_name] }

      result[:timed_out] = proofer_result.timed_out?
      result[:exception] = proofer_result.exception.inspect if proofer_result.exception


      if should_proof_state_id && result[:success]
        proof_state_id(result)
      end

      callback_body = {
        resolution_result: result,
      }

      if block_given?
        yield callback_body
      else
        post_callback(callback_body: callback_body)
      end
    end

    def proof_state_id(result)
      result[:context][:stages].push(state_id: Aamva::Proofer.vendor_name)

      proofer_result = with_retries(**retry_options) do
        aamva_proofer.proof(applicant_pii)
      end

      result.merge(proofer_result.to_h) do |key, orig, current|
        key == :messages ? orig + current : current
      end

      result[:timed_out] = proofer_result.timed_out?
      result[:exception] = proofer_result.exception.inspect if proofer_result.exception

      result
    end

    def set_up_env!
      %w[
        lexisnexis_account_id
        lexisnexis_request_mode
        lexisnexis_username
        lexisnexis_password
        lexisnexis_base_url
        lexisnexis_instant_verify_workflow
        aamva_public_key
        aamva_private_key
      ].each do |env_key|
        ENV[env_key] ||= ssm_helper.load(env_key)
      end
    end

    def post_callback(callback_body:)
      with_retries(**retry_options) do
        Faraday.post(
          callback_url,
          callback_body.to_json,
          "X-API-AUTH-TOKEN" => api_auth_token,
          "Content-Type" => 'application/json',
          "Accept" => 'application/json'
        )
      end
    end

    def lexisnexis_proofer
      LexisNexis::InstantVerify::Proofer.new
    end

    def aamva_proofer
      Aamva::Proofer.new
    end

    def api_auth_token
      @api_auth_token ||= ENV.fetch("IDP_API_AUTH_TOKEN") do
        ssm_helper.load('resolution_proof_result_lambda_token')
      end
    end

    def ssm_helper
      @ssm_helper ||= SsmHelper.new
    end

    def retry_options
      {
        max_tries: 3,
        rescue: [Faraday::TimeoutError, Faraday::ConnectionFailed],
      }
    end
  end
end
