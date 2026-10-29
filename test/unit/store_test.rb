require 'test_helper'

require 'scout_apm/store'

class FakeFailingLayaway
  attr_reader :rps_written
  def write_reporting_period(rp)
    @rps_written ||= []
    @rps_written << rp
  end
end

class StoreTest < Minitest::Test
  # TODO: Introduce a clock object to avoid having to use 'force'
  def test_writing_layaway_removes_timestamps
    s = ScoutApm::Store.new(ScoutApm::AgentContext.new)
    s.track_one!("Controller", "user/show", 10)

    assert_equal(1, s.instance_variable_get('@reporting_periods').size)

    s.write_to_layaway(FakeFailingLayaway.new, true)

    assert_equal({}, s.instance_variable_get('@reporting_periods'))
  end

  def test_writing_layaway_removes_stale_timestamps
    context = ScoutApm::AgentContext.new
    current_time = Time.now.utc
    current_rp = ScoutApm::StoreReportingPeriod.new(current_time, context)
    stale_rp = ScoutApm::StoreReportingPeriod.new(current_time - current_time.sec - 120, context)

    s = ScoutApm::Store.new(context)
    ScoutApm::Instruments::Process::ProcessMemory.new(context).metrics(stale_rp.timestamp, s)
    ScoutApm::Instruments::Process::ProcessMemory.new(context).metrics(current_rp.timestamp, s)
    assert_equal 2, s.instance_variable_get('@reporting_periods').size

    s.write_to_layaway(FakeFailingLayaway.new, true)

    assert_equal({}, s.instance_variable_get('@reporting_periods'))
  end

  def test_forced_write_includes_current_minute_percentiles
    context = ScoutApm::AgentContext.new
    s = ScoutApm::Store.new(context)
    s.add_sampler(ScoutApm::Instruments::PercentileSampler)
    context.request_histograms_by_time[s.current_timestamp].add("Controller/users/index", 100)

    layaway = FakeFailingLayaway.new
    s.write_to_layaway(layaway, true)

    reports = Array(layaway.rps_written).flat_map(&:histograms)
    assert_equal [["Controller/users/index", 1]], reports.map { |report| [report.name, report.histogram.total] }
  end

  def test_write_includes_percentiles_recorded_after_the_tick
    minute = Time.utc(2026, 10, 30, 12, 0, 0)
    context = ScoutApm::AgentContext.new
    s = ScoutApm::Store.new(context)
    s.add_sampler(ScoutApm::Instruments::PercentileSampler)
    layaway = FakeFailingLayaway.new

    Time.stubs(:now).returns(minute + 10)
    context.request_histograms_by_time[s.current_timestamp].add("Controller/users/index", 100)
    s.tick!
    Time.stubs(:now).returns(minute + 50)
    context.request_histograms_by_time[s.current_timestamp].add("Controller/users/index", 900)

    Time.stubs(:now).returns(minute + 70)
    s.tick!
    s.write_to_layaway(layaway)

    report = layaway.rps_written.flat_map(&:histograms).first
    assert_equal [[1, 100], [1, 900]], report.histogram.bins.map { |bin| [bin.count, bin.value] }
  end

  def test_write_just_after_the_tick_crosses_a_minute_writes_the_minute_once
    minute = Time.utc(2026, 10, 30, 12, 0, 0)
    context = ScoutApm::AgentContext.new
    s = ScoutApm::Store.new(context)
    s.add_sampler(ScoutApm::Instruments::PercentileSampler)
    layaway = FakeFailingLayaway.new

    Time.stubs(:now).returns(minute + 30)
    s.track_one!("Controller", "users/index", 100)
    context.request_histograms_by_time[s.current_timestamp].add("Controller/users/index", 100)

    [59.999, 60.001, 119.999, 120.001].each_slice(2) do |tick_at, write_at|
      Time.stubs(:now).returns(minute + tick_at)
      s.tick!
      Time.stubs(:now).returns(minute + write_at)
      s.write_to_layaway(layaway)
    end

    written = layaway.rps_written.select { |rp| rp.timestamp.to_time == minute }
    assert_equal [[1, [1]]], written.map { |rp| [rp.metrics_payload.size, rp.histograms.map { |h| h.histogram.total }] }
  end
end

class StoreReportingPeriodTest < Minitest::Test
  HistogramReport = ScoutApm::Instruments::HistogramReport

  attr_reader :subject

  def setup
    @subject = ScoutApm::StoreReportingPeriod.new(ScoutApm::StoreReportingPeriodTimestamp.new(Time.now), ScoutApm::AgentContext.new)
  end

  # Check default values at creation time
  def test_empty_values
    assert_equal [], subject.histograms
    assert_equal ScoutApm::ScoredItemSet.new, subject.request_traces
    assert_equal ScoutApm::ScoredItemSet.new, subject.job_traces
    assert_equal ScoutApm::MetricSet.new, subject.metric_set
  end

  def test_merge_histograms
    histogramFoo1 = histogram
    histogramFoo2 = histogram
    histogramBar1 = histogram
    histogramBar2 = histogram

    # This assertion may be fragile to reordering in the merge_histograms! function.
    histogramFoo1.expects(:combine!).with(histogramFoo2)
    histogramBar1.expects(:combine!).with(histogramBar2)

    subject.merge_histograms!([
      HistogramReport.new("foo", histogramFoo1),
      HistogramReport.new("bar", histogramBar1),
    ])

    subject.merge_histograms!([
      HistogramReport.new("foo", histogramFoo2),
      HistogramReport.new("bar", histogramBar2),
    ])

    result = subject.histograms
    assert_equal 2, result.length
    assert_equal ["bar", "foo"], result.map(&:name).sort
  end

  ###############################################################################
  # Helpers
  ###############################################################################
  def histogram
    max_bins = 20
    ScoutApm::NumericHistogram.new(max_bins)
  end
end
