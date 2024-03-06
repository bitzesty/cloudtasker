# frozen_string_literal: true

require 'cloudtasker/batch/middleware'

RSpec.describe Cloudtasker::Batch::Job do
  let(:redis) { described_class.redis }
  let(:worker_queue) { 'critical' }
  let(:worker) { TestWorker.new(job_args: [1, 2], job_queue: worker_queue) }
  let(:batch) { described_class.new(worker) }

  let(:child_worker) { worker.new_instance.tap { |e| e.job_meta.set(described_class.key(:parent_id), batch.batch_id) } }
  let(:child_batch) { described_class.new(child_worker) }

  describe '.new' do
    subject { described_class.new(worker) }

    it { is_expected.to have_attributes(worker: worker) }
  end

  describe '.redis' do
    subject { redis }

    it { is_expected.to be_a(Cloudtasker::RedisClient) }
  end

  describe '.for' do
    subject(:batch) { described_class.for(worker) }

    context 'with batch extension loaded' do
      after { expect(worker.batch).to eq(batch) }
      it { is_expected.to be_a(described_class) }
      it { is_expected.to have_attributes(worker: worker) }
    end

    context 'with batch extension not loaded' do
      let(:worker) { TestNonWorker.new }

      before { batch }
      after { expect(worker.batch).to eq(batch) }

      it { is_expected.to be_a(described_class) }
      it { is_expected.to have_attributes(worker: worker) }
      it { expect(worker.class).to be < Cloudtasker::Batch::Extension::Worker }
    end
  end

  describe '.key' do
    subject { described_class.key(val) }

    context 'with value' do
      let(:val) { :some_key }

      it { is_expected.to eq([described_class.to_s.underscore, val.to_s].join('/')) }
    end

    context 'with nil' do
      let(:val) { nil }

      it { is_expected.to be_nil }
    end
  end

  describe '.find' do
    subject { described_class.find(batch_id) }

    let(:batch_id) { batch.batch_id }

    context 'with existing batch' do
      before { batch.save }

      it { is_expected.to be_a(described_class) }
      it { is_expected.to have_attributes(worker: eq(worker)) }
    end

    context 'with invalid batch id' do
      let(:batch_id) { "#{worker.job_id}aaa" }

      it { is_expected.to be_nil }
    end
  end

  describe '#reenqueued?' do
    subject { batch }

    context 'with job reenqueued' do
      before { worker.job_reenqueued = true }

      it { is_expected.to be_reenqueued }
    end

    context 'with job new/enqueued' do
      it { is_expected.not_to be_reenqueued }
    end
  end

  describe '#redis' do
    subject { batch.redis }

    it { is_expected.to be_a(Cloudtasker::RedisClient) }
  end

  describe '#key' do
    subject { batch.key(val) }

    let(:val) { 'foo' }
    let(:resp) { 'bar' }

    before { allow(described_class).to receive(:key).with(val).and_return(resp) }
    it { is_expected.to eq(resp) }
  end

  describe '#==' do
    subject { batch }

    context 'with same batch_id' do
      it { is_expected.to eq(described_class.new(worker)) }
    end

    context 'with different job_id' do
      it { is_expected.not_to eq(described_class.new(child_worker)) }
    end

    context 'with different object' do
      it { is_expected.not_to eq('foo') }
    end
  end

  describe '#parent_batch' do
    subject { child_batch.parent_batch }

    context 'with parent batch' do
      before { batch.save }

      it { is_expected.to eq(batch) }
    end

    context 'with no parent batch' do
      it { is_expected.to be_nil }
    end
  end

  describe '#batch_id' do
    subject { batch.batch_id }

    it { is_expected.to eq(worker.job_id) }
  end

  describe '#batch_gid' do
    subject { batch.batch_gid }

    it { is_expected.to eq(batch.key("#{described_class::JOBS_NAMESPACE}/#{batch.batch_id}")) }
  end

  describe 'batch_state_gid' do
    subject { batch.batch_state_gid }

    it { is_expected.to eq(batch.key("#{described_class::STATES_NAMESPACE}/#{batch.batch_id}")) }
  end

  describe '#jobs' do
    subject { batch.jobs }

    context 'with jobs added' do
      subject { batch.jobs[0] }

      let(:meta_batch_id) { batch.jobs[0].job_meta.get(batch.key(:parent_id)) }

      before { batch.add(child_worker.class, *child_worker.job_args) }
      it { is_expected.to be_a(child_worker.class) }
      it { is_expected.to have_attributes(job_args: child_worker.job_args) }
      it { expect(meta_batch_id).to eq(batch.batch_id) }
    end

    context 'with no jobs' do
      it { is_expected.to eq([]) }
    end
  end

  describe '#batch_state' do
    subject { batch.batch_state }

    before { expect(batch).to receive(:migrate_batch_state_to_redis_hash).and_call_original }

    describe 'with state' do
      let(:state) { { 'some' => 'state' } }

      before { redis.hset(batch.batch_state_gid, state) }
      it { is_expected.to eq(state) }
    end

    describe 'with no state' do
      it { is_expected.to be_empty }
    end
  end

  describe '#add' do
    subject { batch.jobs[0] }

    let(:meta_batch_id) { batch.jobs[0].job_meta.get(batch.key(:parent_id)) }

    before { batch.add(child_worker.class, *child_worker.job_args) }
    it { is_expected.to be_a(child_worker.class) }
    it { is_expected.to have_attributes(job_args: child_worker.job_args, job_queue: worker_queue) }
    it { expect(meta_batch_id).to eq(batch.batch_id) }
  end

  describe '#add_to_queue' do
    subject { batch.jobs[0] }

    let(:queue) { 'low' }
    let(:meta_batch_id) { batch.jobs[0].job_meta.get(batch.key(:parent_id)) }

    before { batch.add_to_queue(queue, child_worker.class, *child_worker.job_args) }
    it { is_expected.to be_a(child_worker.class) }
    it { is_expected.to have_attributes(job_args: child_worker.job_args, job_queue: queue) }
    it { expect(meta_batch_id).to eq(batch.batch_id) }
  end

  describe '#migrate_batch_state_to_redis_hash' do
    subject { batch.batch_state }

    let(:state) { { 'foo1' => 'bar1', 'foo2' => 'bar2' } }

    before do
      redis.write(batch.batch_state_gid, state)
      batch.migrate_batch_state_to_redis_hash
    end

    context 'with state' do
      after { expect(redis.type(batch.batch_state_gid)).to eq('hash') }

      it { is_expected.to eq(state) }
    end

    context 'with blank state' do
      let(:state) { {} }

      after { expect(redis.type(batch.batch_state_gid)).to eq('none') }
      it { is_expected.to eq(state) }
    end
  end

  describe '#save' do
    let(:batch_content) { redis.fetch(batch.batch_gid) }

    before { batch.save }
    it { expect(batch_content).to eq(worker.to_h) }
  end

  describe '#setup' do
    subject(:setup) { batch.setup }

    let(:batch_state) { redis.hgetall(batch.batch_state_gid) }

    context 'with no jobs' do
      before do
        expect(batch).not_to receive(:save)
        expect(child_worker).not_to receive(:schedule)
      end

      it { is_expected.to be_truthy }
    end

    context 'with jobs on the batch' do
      before do
        batch.jobs.push(child_worker)

        expect(batch).to receive(:save)
        expect(child_worker).to receive(:schedule).and_return(true)
      end
      after { expect(batch_state).to eq(batch.jobs[0].job_id => 'scheduled') }

      it { is_expected.to be_truthy }
    end

    context 'with exception while scheduling jobs' do
      let(:error) { StandardError.new }

      before do
        batch.jobs.push(child_worker)

        expect(batch).to receive(:save)
        expect(child_worker).to receive(:schedule).and_raise(error)
      end
      after { expect(batch_state).to be_empty }

      it { expect { setup }.to raise_error(error) }
    end

    context 'with job having completed even before being flagged as scheduled' do
      before do
        batch.jobs.push(child_worker)

        expect(batch).to receive(:save)
        expect(child_worker).to receive(:schedule).and_return(true)
        redis.hset(batch.batch_state_gid, batch.jobs[0].job_id, 'completed')
      end
      after { expect(batch_state).to eq(batch.jobs[0].job_id => 'completed') }

      it { is_expected.to be_truthy }
    end
  end

  describe '#update_state' do
    subject { batch.batch_state&.dig(child_id) }

    let(:child_id) { child_batch.batch_id }
    let(:status) { 'processing' }
    let(:initial_state) { { 'foo' => 'bar' } }

    before do
      redis.hset(batch.batch_state_gid, initial_state) if initial_state.present?
      batch.update_state(child_id, status)
      expect(batch).to receive(:migrate_batch_state_to_redis_hash).and_call_original
    end

    it { is_expected.to eq(status) }
  end

  describe '#complete?' do
    subject { batch }

    before do
      redis.hset(batch.batch_state_gid, 'some_child_id' => status)
      expect(batch).to receive(:migrate_batch_state_to_redis_hash).and_call_original
    end

    %w[completed dead].each do |tested_status|
      context "with all jobs #{tested_status}" do
        let(:status) { tested_status }

        it { is_expected.to be_complete }
      end
    end

    %w[scheduled processing].each do |tested_status|
      context "with some jobs #{tested_status}" do
        let(:status) { tested_status }

        it { is_expected.not_to be_complete }
      end
    end
  end

  describe '#run_worker_callback' do
    subject(:run_worker_callback) { batch.run_worker_callback(callback, *args) }

    let(:callback) { :some_callback }
    let(:args) { [1, 'arg'] }
    let(:resp) { 'some-response' }

    context 'with successful callback' do
      before { allow(worker).to receive(callback).with(*args).and_return(resp) }
      it { is_expected.to eq(resp) }
    end

    context 'with errored callback' do
      before { allow(worker).to receive(callback).and_raise(ArgumentError) }
      it { expect { run_worker_callback }.to raise_error(ArgumentError) }
    end

    context 'with errored on_child_error callback' do
      let(:callback) { :on_child_error }

      before { allow(worker).to receive(callback).and_raise(ArgumentError) }
      it { expect { run_worker_callback }.not_to raise_error }
    end

    context 'with errored on_child_dead callback' do
      let(:callback) { :on_child_dead }

      before { allow(worker).to receive(callback).and_raise(ArgumentError) }
      it { expect { run_worker_callback }.not_to raise_error }
    end
  end

  describe '#on_complete' do
    subject { batch.on_complete(status) }

    let(:status) { :completed }
    let(:parent_batch) { instance_double(described_class.to_s) }

    before { allow(batch).to receive(:parent_batch).and_return(parent_batch) }
    before { allow(batch).to receive(:cleanup).and_return(true) }
    before { allow(batch).to receive(:run_worker_callback).with(:on_batch_complete) }
    before { parent_batch && allow(parent_batch).to(receive(:on_child_complete).with(batch, status)) }

    context 'with no parent batch' do
      let(:parent_batch) { nil }

      after { expect(batch).to have_received(:run_worker_callback) }
      after { expect(batch).to have_received(:cleanup) }
      it { is_expected.to be_truthy }
    end

    context 'with parent batch' do
      after { expect(batch).to have_received(:run_worker_callback) }
      after { expect(batch).to have_received(:cleanup) }
      after { expect(parent_batch).to have_received(:on_child_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with status: dead' do
      let(:status) { :dead }

      after { expect(batch).not_to have_received(:run_worker_callback) }
      after { expect(batch).to have_received(:cleanup) }
      after { expect(parent_batch).to have_received(:on_child_complete) }
      it { is_expected.to be_truthy }
    end
  end

  describe '#on_child_complete' do
    subject { batch.on_child_complete(child_batch, status) }

    let(:status) { :completed }
    let(:complete) { true }

    before { allow(batch).to receive(:complete?).and_return(complete) }
    before { allow(batch).to receive(:on_complete).and_return(true) }
    before { allow(batch).to receive(:update_state).with(child_batch.batch_id, status) }
    before { allow(batch).to receive(:run_worker_callback) }
    before { batch.jobs.push(child_worker) }
    before { batch.save }

    context 'with batch complete' do
      after { expect(batch).to have_received(:update_state) }
      after { expect(batch).to have_received(:run_worker_callback).with(:on_child_complete, child_batch.worker) }
      after { expect(batch).to have_received(:on_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with batch not complete yet' do
      let(:complete) { false }

      after { expect(batch).to have_received(:update_state) }
      after { expect(batch).to have_received(:run_worker_callback).with(:on_child_complete, child_batch.worker) }
      after { expect(batch).not_to have_received(:on_complete) }
      it { is_expected.to be_falsey }
    end

    context 'with status: errored' do
      let(:status) { :errored }

      after { expect(batch).to have_received(:update_state) }
      after { expect(batch).to have_received(:run_worker_callback).with(:on_child_error, child_batch.worker) }
      after { expect(batch).not_to have_received(:on_complete) }
      it { is_expected.to be_falsey }
    end

    context 'with status: dead' do
      let(:status) { :dead }

      after { expect(batch).to have_received(:update_state) }
      after { expect(batch).to have_received(:run_worker_callback).with(:on_child_dead, child_batch.worker) }
      after { expect(batch).to have_received(:on_complete) }
      it { is_expected.to be_truthy }
    end
  end

  describe '#on_batch_node_complete' do
    subject { batch.on_batch_node_complete(child_batch, status) }

    let(:status) { :completed }
    let(:parent_batch) { instance_double(described_class.to_s) }

    before do
      allow(batch).to receive(:parent_batch).and_return(parent_batch)
      allow(batch).to receive(:run_worker_callback).with(:on_batch_node_complete, child_batch.worker)

      if parent_batch
        allow(parent_batch).to(
          receive(:on_batch_node_complete).with(child_batch)
        ).and_return(true)
      end
    end

    context 'with parent batch' do
      after { expect(batch).to have_received(:run_worker_callback) }
      after { expect(parent_batch).to have_received(:on_batch_node_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with no parent batch' do
      let(:parent_batch) { nil }

      after { expect(batch).to have_received(:run_worker_callback) }
      it { is_expected.to be_falsey }
    end

    context 'with status: :errored' do
      let(:status) { :errored }

      after { expect(batch).not_to have_received(:run_worker_callback) }
      after { expect(parent_batch).not_to have_received(:on_batch_node_complete) }
      it { is_expected.to be_falsey }
    end

    context 'with status: :dead' do
      let(:status) { :dead }

      after { expect(batch).not_to have_received(:run_worker_callback) }
      after { expect(parent_batch).not_to have_received(:on_batch_node_complete) }
      it { is_expected.to be_falsey }
    end
  end

  describe '#cleanup' do
    subject { redis.keys.sort }

    let(:side_batch) { described_class.new(worker.new_instance) }
    let(:expected_keys) { [side_batch.batch_gid, side_batch.batch_state_gid].sort }

    before do
      # Do not enqueue jobs
      allow_any_instance_of(Cloudtasker::Worker).to receive(:schedule)

      # Create un-related batch
      side_batch.jobs.push(worker.new_instance)
      side_batch.setup

      # Create child batch
      child_batch.jobs.push(worker.new_instance)
      child_batch.jobs.push(worker.new_instance)
      child_batch.jobs.push(worker.new_instance)
      child_batch.setup

      # Attach child batch to main batch
      batch.jobs.push(child_worker)
      batch.setup

      expect(batch).to receive(:migrate_batch_state_to_redis_hash).and_call_original
      batch.cleanup
    end

    it { is_expected.to eq(expected_keys) }
  end

  describe '#progress' do
    subject { batch.progress(depth: depth) }

    let(:depth) { 0 }

    before do
      # Stub job enqueuing
      allow_any_instance_of(Cloudtasker::Worker).to receive(:schedule)

      # Add child jobs
      child_batch.jobs.push(worker.new_instance)
      child_batch.jobs.push(worker.new_instance)
      child_batch.jobs.push(worker.new_instance)
      child_batch.setup

      # Update progress status on children
      child_batch.update_state(child_batch.jobs[0].job_id, 'completed')
      child_batch.update_state(child_batch.jobs[1].job_id, 'processing')

      # Expand batch with new child job
      batch.jobs.push(child_worker)
      batch.setup
    end

    context 'with depth = 0' do
      it { is_expected.to be_a(Cloudtasker::Batch::BatchProgress) }
      it { is_expected.to have_attributes(total: 1, completed: 0, scheduled: 1, processing: 0) }
    end

    context 'with depth = 1' do
      let(:depth) { 1 }

      it { is_expected.to be_a(Cloudtasker::Batch::BatchProgress) }
      it { is_expected.to have_attributes(total: 4, completed: 1, scheduled: 2, processing: 1) }
    end

    context 'with nil depth' do
      let(:depth) { nil }

      it { is_expected.to be_a(Cloudtasker::Batch::BatchProgress) }
      it { is_expected.to have_attributes(total: 1, completed: 0, scheduled: 1, processing: 0) }
    end
  end

  describe '#complete' do
    subject { batch.complete(status) }

    let(:status) { :completed }
    let(:complete) { false }
    let(:parent_batch) { instance_double(described_class.to_s) }

    before do
      allow(batch).to receive(:complete?).and_return(complete)
      allow(batch).to receive(:parent_batch).and_return(parent_batch)
      allow(batch).to receive(:on_complete).with(status)

      allow(parent_batch).to(receive(:on_batch_node_complete).with(batch, status)).and_return(true) if parent_batch
    end

    context 'with job reenqueued' do
      before { worker.job_reenqueued = true }
      after { expect(batch).not_to have_received(:on_complete) }
      after { expect(parent_batch).not_to have_received(:on_batch_node_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with child jobs' do
      before { batch.jobs.push(worker.new_instance) }
      after { expect(batch).not_to have_received(:on_complete) }
      after { expect(parent_batch).not_to have_received(:on_batch_node_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with batch incomplete' do
      after { expect(batch).not_to have_received(:on_complete) }
      after { expect(parent_batch).to have_received(:on_batch_node_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with batch complete' do
      let(:complete) { true }

      after { expect(batch).to have_received(:on_complete) }
      after { expect(parent_batch).to have_received(:on_batch_node_complete) }
      it { is_expected.to be_truthy }
    end

    context 'with batch complete no parent batch' do
      let(:complete) { true }

      after { expect(batch).to have_received(:on_complete) }
      it { is_expected.to be_truthy }
    end
  end

  describe '#execute' do
    subject { batch.execute }

    let(:batch_jobs) { [1, 2] }
    let(:parent_batch_jobs) { [] }

    let(:parent_batch) { instance_double(described_class, jobs: parent_batch_jobs) }

    before do
      allow(batch).to receive(:parent_batch).and_return(parent_batch)
      allow(batch).to receive(:jobs).and_return(batch_jobs)
    end

    context 'with parent_batch and child jobs added' do
      before do
        expect(parent_batch).to receive(:update_state).with(batch.batch_id, :processing)
        expect(batch).to receive(:setup)
        expect(batch).to receive(:complete).with(:completed)
      end

      it { expect { |b| batch.execute(&b) }.to yield_control }
    end

    context 'with parent_batch and parent jobs added' do
      let(:batch_jobs) { [] }
      let(:parent_batch_jobs) { [1, 2] }

      before do
        expect(parent_batch).to receive(:update_state).with(batch.batch_id, :processing)
        expect(batch).not_to receive(:setup)
        expect(parent_batch).to receive(:setup)
        expect(batch).to receive(:complete).with(:completed)
      end

      it { expect { |b| batch.execute(&b) }.to yield_control }
    end

    context 'with parent_batch and child + parent jobs added' do
      let(:batch_jobs) { [1, 2] }
      let(:parent_batch_jobs) { [1, 2] }

      before do
        expect(parent_batch).to receive(:update_state).with(batch.batch_id, :processing)
        expect(batch).to receive(:setup)
        expect(parent_batch).to receive(:setup)
        expect(batch).to receive(:complete).with(:completed)
      end

      it { expect { |b| batch.execute(&b) }.to yield_control }
    end

    context 'with no parent batch and child jobs added' do
      let(:parent_batch) { nil }

      before do
        expect(batch).to receive(:setup)
        expect(batch).to receive(:complete).with(:completed)
      end

      it { expect { |b| batch.execute(&b) }.to yield_control }
    end

    context 'with runtime error' do
      let(:error) { ArgumentError.new }
      let(:block) { proc { raise(error) } }

      before do
        expect(parent_batch).to receive(:update_state).with(batch.batch_id, :processing)
        expect(batch).not_to receive(:setup)
        expect(batch).to receive(:complete).with(:errored)
      end

      it { expect { batch.execute(&block) }.to raise_error(error) }
    end

    context 'with dead error' do
      let(:error) { Cloudtasker::DeadWorkerError.new }
      let(:block) { proc { raise(error) } }

      before do
        expect(parent_batch).to receive(:update_state).with(batch.batch_id, :processing)
        expect(batch).not_to receive(:setup)
        expect(batch).to receive(:complete).with(:dead)
      end

      it { expect { batch.execute(&block) }.to raise_error(error) }
    end
  end
end
