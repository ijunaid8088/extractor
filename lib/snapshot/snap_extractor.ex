defmodule Extractor.SnapExtractor do
  @new_filer "#{System.get_env["FILER_NEW"]}"

  def extract(nil), do: IO.inspect "No extrator with status 0"
  def extract(extractor) do
    IO.inspect extractor
    time_start = Calendar.DateTime.now_utc
    schedule = extractor.schedule
    interval = extractor.interval |> intervaling
    requestor = extractor.requestor
    camera_exid = extractor.camera_exid
    {:ok, agent} = Agent.start_link fn -> [] end
    {:ok, t_agent} = Agent.start_link fn -> [] end

    timezone =
      case extractor.timezone do
        nil -> "Etc/UTC"
        _ -> extractor.timezone
      end

    start_date =
      extractor.from_date
      |> Ecto.DateTime.to_erl
      |> Calendar.DateTime.from_erl!(timezone)

    end_date =
      extractor.to_date
      |> Ecto.DateTime.to_erl
      |> Calendar.DateTime.from_erl!(timezone)

    total_days = find_difference(end_date, start_date) / 86400 |> round |> round_2

    e_start_date = start_date |> Calendar.Strftime.strftime!("%A, %b %d %Y, %H:%M")
    e_to_date = end_date |> Calendar.Strftime.strftime!("%A, %b %d %Y, %H:%M")
    e_schedule = schedule
    e_interval = interval |> humanize_interval

    construction =
      case requestor do
        "marklensmen@gmail.com" ->
          "Construction"
        _ ->
          "Construction2"
      end

    images_directory = "#{construction}/#{camera_exid}/#{extractor.id}"
    File.mkdir_p(images_directory)
    case SnapshotExtractor.update_extractor_status(extractor.id, %{status: 1}) do
      {:ok, _extractor} ->
        send_mail_start(Application.get_env(:extractor, :send_emails_for_extractor), e_start_date, e_to_date, e_schedule, e_interval, extractor.camera_name, requestor)
        ElixirDropbox.Files.create_folder(ElixirDropbox.Client.new(System.get_env["DROP_BOX_TOKEN"]), "/#{construction}/#{camera_exid}/#{extractor.id}")
      _ ->
        IO.inspect "Status update failed!"
    end

    1..total_days |> Enum.reduce(start_date, fn _i, acc ->
      day_of_week = acc |> Calendar.Date.day_of_week_name
      rec_head = get_head_tail(schedule[day_of_week])
      rec_head |> Enum.each(fn(x) ->
        iterate(x, acc, timezone) |> t_download(interval, t_agent)
      end)
      acc |> Calendar.DateTime.to_erl |> Calendar.DateTime.from_erl(timezone, {123456, 6}) |> ambiguous_handle |> Calendar.DateTime.add!(86400)
    end)

    1..total_days |> Enum.reduce(start_date, fn _i, acc ->
      IO.inspect acc
      %DateTime{month: month, year: year} = acc
      url_day = "#{switch_filer(acc)}/#{camera_exid}/snapshots/recordings/"
      with :ok <- ensure_a_day(acc, url_day)
      do
        day_of_week = acc |> Calendar.Date.day_of_week_name
        rec_head = get_head_tail(schedule[day_of_week])
        rec_head |> Enum.each(fn(x) ->
          iterate(x, acc, timezone) |> download(camera_exid, interval, extractor.id, agent, requestor)
        end)
        acc |> Calendar.DateTime.to_erl |> Calendar.DateTime.from_erl(timezone, {123456, 6}) |> ambiguous_handle |> Calendar.DateTime.add!(86400)
      else
        :not_ok ->
          acc |> Calendar.DateTime.to_erl |> Calendar.DateTime.from_erl(timezone, {123456, 6}) |> ambiguous_handle |> Calendar.DateTime.add!(86400)
      end
    end)

    time_end = Calendar.DateTime.now_utc
    count =
      Agent.get(agent, fn list -> list end)
      |> Enum.filter(fn(item) -> item end)
      |> Enum.count

    expected_count =
      Agent.get(t_agent, fn list -> list end)
      |> Enum.filter(fn(item) -> item end)
      |> Enum.count

    {:ok, secs, _msecs, :after} = Calendar.DateTime.diff(time_end, time_start)
    execution_time = humanize_time(secs)

    # crtea_mp4_file
    spawn fn ->
      IO.inspect "Spawing Mp4 file"
      create_mp4_and_upload(extractor.create_mp4, images_directory)
    end

    case SnapshotExtractor.update_extractor_status(extractor.id, %{status: 2, notes: "Extracted Images = #{count} -- Expected Count = #{expected_count}"}) do
      {:ok, _} ->
        instruction = %{
          from_date: e_start_date,
          to_date: e_to_date,
          schedule: e_schedule,
          frequency: e_interval,
          execution_time: execution_time
        }
        File.write("#{construction}/#{camera_exid}/#{extractor.id}/instruction.json", Poison.encode!(instruction), [:binary])
        ElixirDropbox.Files.upload(ElixirDropbox.Client.new(System.get_env["DROP_BOX_TOKEN"]), "/#{construction}/#{camera_exid}/#{extractor.id}/instruction.json", "#{construction}/#{camera_exid}/#{extractor.id}/instruction.json")
        IO.inspect "instruction written"
        send_mail_end(Application.get_env(:extractor, :send_emails_for_extractor), count, extractor.camera_name, expected_count, extractor.id, camera_exid, requestor, execution_time)
      _ -> IO.inspect "Status update failed!"
    end
  end

  defp switch_filer(request_date) do
    oct_date =
      {{2017, 10, 31}, {23, 59, 59}}
      |> Calendar.DateTime.from_erl!("UTC")

    case Calendar.DateTime.diff(request_date, oct_date) do
      {:ok, secs, _, :after} ->
        case secs > 31536000 do
          true -> "#{System.get_env["FILER_NEW"]}"
          false -> "#{System.get_env["FILER_NOV"]}"
        end
      _ -> "#{System.get_env["FILER"]}"
    end
  end

  defp create_mp4_and_upload(false, images_directory), do: File.rm_rf!(images_directory)
  defp create_mp4_and_upload(true, images_directory) do
    Porcelain.shell("cat #{images_directory}/*.jpg | ffmpeg -f image2pipe -framerate 6 -i - -c:v libx264 -r 6 -preset slow -tune stillimage -bufsize 1000k -pix_fmt yuv420p -y #{images_directory}/video.mp4", [err: :out]).out
    ElixirDropbox.Files.upload(ElixirDropbox.Client.new(System.get_env["DROP_BOX_TOKEN"]), "/#{images_directory}/video.mp4", "#{images_directory}/video.mp4")
    File.rm_rf!(images_directory)
  end

  defp humanize_time(seconds) do
    Float.floor(seconds / 60)
  end

  defp ambiguous_handle(value) do
    case value do
      {:ok, datetime} -> datetime
      {:ambiguous, datetime} -> datetime.possible_date_times |> hd
    end
  end

  defp get_head_tail([]), do: []
  defp get_head_tail(nil), do: []
  defp get_head_tail([head|tail]) do
    [[head]|get_head_tail(tail)]
  end

  def t_download([], _interval, _t_agent), do: IO.inspect "I am empty!"
  def t_download([starting, ending], interval, t_agent) do
    t_do_loop(starting, ending, interval, t_agent)
  end

  defp t_do_loop(starting, ending, _interval, _t_agent) when starting >= ending, do: IO.inspect "We are finished!"
  defp t_do_loop(starting, ending, interval, t_agent) do
    Agent.update(t_agent, fn list -> ["true" | list] end)
    t_do_loop(starting + interval, ending, interval, t_agent)
  end

  def download([], _camera_exid, _interval, _id, _agent, _requestor), do: IO.inspect "I am empty!"
  def download([starting, ending], camera_exid, interval, id, agent, requestor) do
    do_loop(starting, ending, interval, camera_exid, id, agent, requestor, 0)
  end

  defp do_loop(starting, ending, _interval, _camera_exid, _id, _agent, _requestor, _index) when starting >= ending, do: IO.inspect "We are finished!"
  defp do_loop(starting, ending, interval, camera_exid, id, agent, requestor, index) do
    IO.inspect "#{index} INDEX"
    %{year: yearing, month: monthing} = Calendar.DateTime.Parse.unix!(starting)
    %{year: year, month: month, day: day, hour: hour, min: min, sec: sec} = make_me_complete(starting)
    url = "#{switch_filer(Calendar.DateTime.Parse.unix!(starting))}/#{camera_exid}/snapshots/recordings/#{year}/#{month}/#{day}/#{hour}/#{min}_#{sec}_000.jpg"
    IO.inspect url
    case HTTPoison.get(url, [], []) do
      {:ok, %HTTPoison.Response{body: body, status_code: 200}} ->
        upload(200, body, starting, camera_exid, id, agent, requestor, index)
        IO.inspect "Going for NEXT!"
        do_loop(starting + interval, ending, interval, camera_exid, id, agent, requestor, index + 1)
      {:ok, %HTTPoison.Response{body: "", status_code: 404}} ->
        add_up = the_most_nearest(url = "#{switch_filer(Calendar.DateTime.Parse.unix!(starting))}/#{camera_exid}/snapshots/recordings/#{year}/#{month}/#{day}/#{hour}/?limit=3600", starting)
        # add_up = the_most_nearest(url = "#{System.get_env["FILER"]}/#{camera_exid}/snapshots/recordings/#{year}/#{month}/#{day}/#{hour}/?limit=3600", starting)
        IO.inspect add_up
        IO.inspect "Getting nearest!"
        do_loop(starting + add_up, ending, interval, camera_exid, id, agent, requestor, index + 1)
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.inspect "Weed: #{reason}!"
        :timer.sleep(:timer.seconds(3))
        do_loop(starting, ending, interval, camera_exid, id, agent, requestor, index)
    end
  end

  defp seaweefs_type(@new_filer), do: "Entries"
  defp seaweefs_type(_), do: "Directories"

  defp seaweedfs_attribute(@new_filer), do: "FullPath"
  defp seaweedfs_attribute(_), do: "Name"

  defp seaweedfs_files(@new_filer), do: "Entries"
  defp seaweedfs_files(_), do: "Files"

  defp seaweedfs_name(@new_filer), do: "FullPath"
  defp seaweedfs_name(_), do: "name"

  defp the_most_nearest(url, starting) do
    date_on = Calendar.DateTime.Parse.unix!(starting)
    %{year: _year, month: _month, day: _day, hour: _hour, min: min, sec: sec} = make_me_complete(starting)
    on_miss = "#{min}_#{sec}_000.jpg"
    IO.inspect on_miss
    filer = switch_filer(date_on)

    request_from_seaweedfs(url, seaweedfs_files(filer), seaweedfs_name(filer))
    |> case do
      [] ->
        [r_min, r_sec, _] = String.split(on_miss, "_")
        r_second = Integer.parse(r_sec) |> elem(0)
        r_minute =  Integer.parse(r_min) |> elem(0)
        recent_secs = (r_minute * 60) + r_second
        3600 - recent_secs
      files ->
        files |> Enum.uniq |> Enum.sort |> Enum.filter(fn(file) -> file > on_miss end) |> List.first |> IO.inspect |> nearest_min_sec(on_miss)
    end
  end

  defp nearest_min_sec(nil, recent_file) do
    [r_min, r_sec, _] = String.split(recent_file, "_")
    r_second = Integer.parse(r_sec) |> elem(0)
    r_minute =  Integer.parse(r_min) |> elem(0)
    recent_secs = (r_minute * 60) + r_second
    3600 - recent_secs
  end
  defp nearest_min_sec(near_file, recent_file) do
    [n_min, n_sec, _] = String.split(near_file, "_")
    n_second = Integer.parse(n_sec) |> elem(0)
    n_minute =  Integer.parse(n_min) |> elem(0)
    [r_min, r_sec, _] = String.split(recent_file, "_")
    r_second = Integer.parse(r_sec) |> elem(0)
    r_minute =  Integer.parse(r_min) |> elem(0)
    near_secs = (n_minute * 60) + n_second
    recent_secs = (r_minute * 60) + r_second
    near_secs - recent_secs
  end

  def get_ending_hour(ending_hour, ending_minutes) do
    case ending_minutes > 0 do
      true -> ending_hour + 1
      false -> ending_hour
    end
  end

  def upload(200, response, starting, camera_exid, id, agent, requestor, index) do
    construction =
      case requestor do
        "marklensmen@gmail.com" ->
          "Construction"
        _ ->
          "Construction2"
      end

    IO.inspect response

    image_save_path = "#{construction}/#{camera_exid}/#{id}/#{starting}.jpg"
    imagef = File.write(image_save_path, response, [:binary])
    IO.inspect "writing"
    File.close imagef

    case ElixirDropbox.Files.upload(ElixirDropbox.Client.new(System.get_env["DROP_BOX_TOKEN"]), "/#{construction}/#{camera_exid}/#{id}/#{starting}.jpg", image_save_path) do
      {{:status_code, status_code}, _} ->
        IO.inspect status_code
        :timer.sleep(:timer.seconds(3))
        upload(200, response, starting, camera_exid, id, agent, requestor)
      _ ->
        Agent.update(agent, fn list -> ["true" | list] end)
        IO.inspect "written"
    end
  end
  def upload(_, response, _starting, _camera_exid, _id, _agent, _requestor), do: IO.inspect "Not an Image! #{response}"

  defp decode_image("data:image/jpeg;base64," <> encoded_image) do
    Base.decode64!(encoded_image)
  end

  defp find_difference(end_date, start_date) do
    case Calendar.DateTime.diff(end_date, start_date) do
      {:ok, seconds, _, :after} -> seconds
      _ -> 1
    end
  end

  def iterate([], _check_time, _timezone), do: []
  def iterate([head], check_time, timezone) do
    [from, to] = String.split head, "-"
    [from_hour, from_minute] = String.split from, ":"
    [to_hour, to_minute] = String.split to, ":"

    from_unix_timestamp = unix_timestamp(from_hour, from_minute, check_time, timezone)
    to_unix_timestamp = unix_timestamp(to_hour, to_minute, check_time, timezone)
    [from_unix_timestamp, to_unix_timestamp]
  end

  defp unix_timestamp(hours, minutes, date, nil) do
    unix_timestamp(hours, minutes, date, "UTC")
  end
  defp unix_timestamp(hours, minutes, date, timezone) do
    %{year: year, month: month, day: day} = date
    {h, _} = Integer.parse(hours)
    {m, _} = Integer.parse(minutes)
    erl_date_time = {{year, month, day}, {h, m, 0}}
    case Calendar.DateTime.from_erl(erl_date_time, timezone) do
      {:ok, datetime} -> datetime |> Calendar.DateTime.Format.unix
      {:ambiguous, datetime} -> datetime.possible_date_times |> hd |> Calendar.DateTime.Format.unix
      _ -> raise "Timezone conversion error"
    end
  end

  defp round_2(0), do: 2
  defp round_2(n), do: n + 1

  defp intervaling(0), do: 1
  defp intervaling(n), do: n

  defp send_mail_start(false, _e_start_date, _e_to_date, _e_schedule, _e_interval, _camera_name, _requestor), do: IO.inspect "We are in Development Mode!"
  defp send_mail_start(true, e_start_date, e_to_date, e_schedule, e_interval, camera_name, requestor), do: Extractor.ExtractMailer.extractor_started(e_start_date, e_to_date, e_schedule, e_interval, camera_name, requestor)

  defp send_mail_end(false, _count, _camera_name, _expected_count, _extractor_id, _camera_exid, _requestor, _execution_time), do: IO.inspect "We are in Development Mode!"
  defp send_mail_end(true, count, camera_name, expected_count, extractor_id, camera_exid, requestor, execution_time), do: Extractor.ExtractMailer.extractor_completed(count, camera_name, expected_count, extractor_id, camera_exid, requestor, execution_time)

  defp make_me_complete(date) do
    # %{year: year, month: month, day: day, hour: hour, min: min, sec: sec} = Calendar.DateTime.Parse.unix! date
    {{year, month, day}, {hour, min, sec}} = Calendar.DateTime.Parse.unix!(date) |> Calendar.DateTime.to_erl
    month = String.pad_leading("#{month}", 2, "0")
    day = String.pad_leading("#{day}", 2, "0")
    hour = String.pad_leading("#{hour}", 2, "0")
    min = String.pad_leading("#{min}", 2, "0")
    sec = String.pad_leading("#{sec}", 2, "0")
    %{year: year, month: month, day: day, hour: hour, min: min, sec: sec}
  end

  defp humanize_interval(5),     do: "1 Frame Every 5 sec"
  defp humanize_interval(10),    do: "1 Frame Every 10 sec"
  defp humanize_interval(15),    do: "1 Frame Every 15 sec"
  defp humanize_interval(20),    do: "1 Frame Every 20 sec"
  defp humanize_interval(30),    do: "1 Frame Every 30 sec"
  defp humanize_interval(60),    do: "1 Frame Every 1 min"
  defp humanize_interval(300),   do: "1 Frame Every 5 min"
  defp humanize_interval(600),   do: "1 Frame Every 10 min"
  defp humanize_interval(900),   do: "1 Frame Every 15 min"
  defp humanize_interval(1200),  do: "1 Frame Every 20 min"
  defp humanize_interval(1800),  do: "1 Frame Every 30 min"
  defp humanize_interval(3600),  do: "1 Frame Every hour"
  defp humanize_interval(7200),  do: "1 Frame Every 2 hour"
  defp humanize_interval(21600), do: "1 Frame Every 6 hour"
  defp humanize_interval(43200), do: "1 Frame Every 12 hour"
  defp humanize_interval(86400), do: "1 Frame Every 24 hour"
  defp humanize_interval(1),     do: "All"

  defp request_from_seaweedfs(url, type, attribute) do
    hackney = [recv_timeout: 15000]
    with {:ok, response} <- HTTPoison.get(url, ["Accept": "application/json"], hackney: hackney),
         %HTTPoison.Response{status_code: 200, body: body} <- response,
         {:ok, data} <- Poison.decode(body),
         true <- is_list(data[type]) do
      Enum.map(data[type], fn(item) -> item[attribute] |> get_base_name(type, attribute) end)
    else
      _ -> []
    end
  end

  defp get_base_name(list, "Entries", "FullPath"), do: list |> Path.basename
  defp get_base_name(list, _, _), do: list

  defp ensure_a_day(date, url) do
    filer = switch_filer(date)
    day = Calendar.Strftime.strftime!(date, "%Y/%m/%d/")
    url_day = url <> "#{day}"
    case request_from_seaweedfs(url_day, seaweefs_type(filer), seaweedfs_attribute(filer)) |> Enum.empty? do
      true -> :not_ok
      false -> :ok
    end
  end
end
