# frozen_string_literal: true

require 'spec_helper'

if defined?(Rails)
  RSpec.describe Cloudtasker::WorkerController, type: :controller do
    routes { Cloudtasker::Engine.routes }

    describe 'POST #run' do
      subject { post :run, body: request_body, as: mime_type }

      let(:payload) do
        {
          'worker' => worker_class_name,
          'job_id' => id,
          'job_args' => args,
          'job_meta' => meta,
          'job_queue' => queue,
          'other' => 'foo'
        }
      end
      let(:mime_type) { :json }
      let(:request_body) { payload.to_json }
      let(:expected_payload) { payload.merge(job_retries: retries, task_id: task_id) }
      let(:task_id) { 'ab2341f' }
      let(:id) { '111' }
      let(:worker_class_name) { 'TestWorker' }
      let(:args) { [1, 2] }
      let(:meta) { { 'foo' => 'bar' } }
      let(:retries) { 3 }
      let(:queue) { 'some-queue' }
      let(:auth_token) { Cloudtasker::Authenticator.verification_token }
      let(:env_retries_header) { "HTTP_#{Cloudtasker::Config::RETRY_HEADER.tr('-', '_').upcase}" }
      let(:env_task_id_header) { "HTTP_#{Cloudtasker::Config::TASK_ID_HEADER.tr('-', '_').upcase}" }

      before do
        request.env[env_retries_header] = retries
        request.env[env_task_id_header] = task_id
      end

      context 'with valid worker' do
        before do
          request.env['HTTP_X_CLOUDTASKER_AUTHORIZATION'] = "Bearer #{auth_token}"
          expect(Cloudtasker::WorkerHandler).to receive(:execute_from_payload!)
            .with(expected_payload)
            .and_return(true)
        end
        it { is_expected.to be_successful }
      end

      context 'with legacy authorization header' do
        before do
          request.env['HTTP_AUTHORIZATION'] = "Bearer #{auth_token}"
          expect(Cloudtasker::WorkerHandler).to receive(:execute_from_payload!)
            .with(expected_payload)
            .and_return(true)
        end
        it { is_expected.to be_successful }
      end

      context 'with base64 encoded body' do
        let(:mime_type) { :text }
        let(:request_body) { Base64.encode64(payload.to_json) }

        before do
          request.env['HTTP_X_CLOUDTASKER_AUTHORIZATION'] = "Bearer #{auth_token}"
          request.env['HTTP_CONTENT_TRANSFER_ENCODING'] = 'BASE64'
          expect(Cloudtasker::WorkerHandler).to receive(:execute_from_payload!)
            .with(expected_payload)
            .and_return(true)
        end
        it { is_expected.to be_successful }
      end

      context 'with execution errors' do
        before do
          request.env['HTTP_X_CLOUDTASKER_AUTHORIZATION'] = "Bearer #{auth_token}"
          allow(Cloudtasker::WorkerHandler).to receive(:execute_from_payload!)
            .with(expected_payload)
            .and_raise(ArgumentError)
        end
        it { is_expected.to have_http_status(:unprocessable_entity) }
      end

      context 'with dead worker' do
        before do
          request.env['HTTP_X_CLOUDTASKER_AUTHORIZATION'] = "Bearer #{auth_token}"
          allow(Cloudtasker::WorkerHandler).to receive(:execute_from_payload!)
            .with(expected_payload)
            .and_raise(Cloudtasker::DeadWorkerError)
        end
        it { is_expected.to have_http_status(:reset_content) }
      end

      context 'with invalid worker' do
        before do
          request.env['HTTP_X_CLOUDTASKER_AUTHORIZATION'] = "Bearer #{auth_token}"
          allow(Cloudtasker::WorkerHandler).to receive(:execute_from_payload!)
            .with(expected_payload)
            .and_raise(Cloudtasker::InvalidWorkerError)
        end
        it { is_expected.to have_http_status(:not_found) }
      end

      context 'with no authentication' do
        it { is_expected.to have_http_status(:unauthorized) }
      end

      context 'with invalid authentication' do
        before { request.env['HTTP_X_CLOUDTASKER_AUTHORIZATION'] = "Bearer #{auth_token}aaa" }
        it { is_expected.to have_http_status(:unauthorized) }
      end
    end
  end
end
