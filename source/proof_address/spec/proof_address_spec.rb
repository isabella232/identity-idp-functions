require 'securerandom'
require 'identity-idp-functions/proof_address'
require 'shared_examples_for_proofers'

RSpec.describe IdentityIdpFunctions::ProofAddress do
  let(:idp_api_auth_token) { SecureRandom.hex }
  let(:callback_url) { 'https://example.login.gov/api/callbacks/proof-address/:token' }
  let(:trace_id) { SecureRandom.uuid }
  let(:applicant_pii) do
    {
      first_name: 'Johnny',
      last_name: 'Appleseed',
      uuid: SecureRandom.hex,
      dob: '01/01/1970',
      ssn: '123456789',
      phone: '18888675309',
    }
  end

  before do
    stub_const(
      'ENV',
      'IDP_API_AUTH_TOKEN' => idp_api_auth_token,
      'lexisnexis_account_id' => 'abc123',
      'lexisnexis_request_mode' => 'aaa',
      'lexisnexis_username' => 'aaa',
      'lexisnexis_password' => 'aaa',
      'lexisnexis_base_url' => 'https://lexisnexis.example.com/',
      'lexisnexis_phone_finder_workflow' => 'aaa',
    )
  end

  describe '.handle' do
    before do
      stub_request(
        :post,
        'https://lexisnexis.example.com/restws/identity/v2/abc123/aaa/conversation',
      ).to_return(
        body: { 'Status' => { 'TransactionStatus' => 'passed' } }.to_json,
      )

      stub_request(:post, callback_url).
        with(
          headers: {
            'Content-Type' => 'application/json',
            'X-API-AUTH-TOKEN' => idp_api_auth_token,
          },
        ) do |request|
          expect(JSON.parse(request.body, symbolize_names: true)).to eq(
            address_result: {
              exception: nil,
              errors: {},
              messages: [],
              success: true,
              timed_out: false,
              context: { stages: [
                { address: 'lexisnexis:phone_finder' },
              ] },
            },
          )
        end
    end

    let(:event) do
      {
        callback_url: callback_url,
        applicant_pii: applicant_pii,
        trace_id: trace_id,
      }
    end

    it 'runs' do
      IdentityIdpFunctions::ProofAddress.handle(event: event, context: nil)
    end

    context 'when called with a block' do
      it 'gives the results to the block instead of posting to the callback URL' do
        yielded_result = nil
        IdentityIdpFunctions::ProofAddress.handle(
          event: event,
          context: nil,
        ) do |result|
          yielded_result = result
        end

        expect(yielded_result).to eq(
          address_result: {
            exception: nil,
            errors: {},
            messages: [],
            success: true,
            timed_out: false,
            context: { stages: [
              { address: 'lexisnexis:phone_finder' },
            ] },
          },
        )

        expect(a_request(:post, callback_url)).to_not have_been_made
      end
    end
  end

  describe '#proof' do
    subject(:function) do
      IdentityIdpFunctions::ProofAddress.new(
        callback_url: callback_url,
        applicant_pii: applicant_pii,
        trace_id: trace_id,
      )
    end

    let(:lexisnexis_proofer) { instance_double(LexisNexis::PhoneFinder::Proofer) }

    before do
      allow(function).to receive(:lexisnexis_proofer).and_return(lexisnexis_proofer)

      stub_request(:post, callback_url).
        with(headers: { 'X-API-AUTH-TOKEN' => idp_api_auth_token })
    end

    context 'with a successful response from the proofer' do
      before do
        expect(lexisnexis_proofer).to receive(:proof).
          and_return(Proofer::Result.new)
      end

      it 'posts back to the callback url' do
        function.proof

        expect(WebMock).to have_requested(:post, callback_url)
      end

      it_behaves_like 'callback url behavior'

      it 'logs the trace_id and timing info' do
        expect(function).to receive(:log_event).with(hash_including(:timing, trace_id: trace_id))

        function.proof
      end
    end

    context 'with an unsuccessful response from the proofer' do
      before do
        expect(lexisnexis_proofer).to receive(:proof).
          and_return(Proofer::Result.new(exception: RuntimeError.new))
      end

      it 'posts back to the callback url' do
        function.proof

        expect(WebMock).to have_requested(:post, callback_url)
      end
    end

    context 'with a connection error talking to the proofer' do
      before do
        allow(lexisnexis_proofer).to receive(:proof).
          and_raise(Faraday::ConnectionFailed.new('error')).
          and_raise(Faraday::ConnectionFailed.new('error')).
          and_raise(Faraday::ConnectionFailed.new('error'))
      end

      it 'retries 3 times then errors' do
        expect { function.proof }.to raise_error(Faraday::ConnectionFailed)

        expect(WebMock).to_not have_requested(:post, callback_url)
      end
    end

    context 'when IDP auth token is blank' do
      it_behaves_like 'misconfigured proofer'
    end

    context 'when there are no params in the ENV' do
      before do
        ENV.clear

        expect(lexisnexis_proofer).to receive(:proof).
          and_return(Proofer::Result.new)
      end

      it 'loads secrets from SSM and puts them in the ENV' do
        expect(function.ssm_helper).to receive(:load).
          with('address_proof_result_token').and_return(idp_api_auth_token)
        expect(function.ssm_helper).to receive(:load).
          with('lexisnexis_account_id').and_return('aaa')
        expect(function.ssm_helper).to receive(:load).
          with('lexisnexis_request_mode').and_return('aaa')
        expect(function.ssm_helper).to receive(:load).
          with('lexisnexis_username').and_return('aaa')
        expect(function.ssm_helper).to receive(:load).
          with('lexisnexis_password').and_return('aaa')
        expect(function.ssm_helper).to receive(:load).
          with('lexisnexis_base_url').and_return('aaa')
        expect(function.ssm_helper).to receive(:load).
          with('lexisnexis_phone_finder_workflow').and_return('aaa')

        function.proof

        expect(WebMock).to have_requested(:post, callback_url)

        expect(ENV).to include(
          'lexisnexis_account_id' => 'aaa',
          'lexisnexis_request_mode' => 'aaa',
          'lexisnexis_username' => 'aaa',
          'lexisnexis_password' => 'aaa',
          'lexisnexis_base_url' => 'aaa',
          'lexisnexis_phone_finder_workflow' => 'aaa',
        )
      end
    end
  end
end
