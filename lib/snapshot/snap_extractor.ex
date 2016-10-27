defmodule Extractor.SnapExtractor do

  def extract(nil), do: IO.inspect "No extrator with status 0"
  def extract(extractor) do
    schedule = extractor.schedule
    interval = extractor.interval |> intervaling
    camera_exid = extractor.camera_exid
    {:ok, agent} = Agent.start_link fn -> [] end

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

    case SnapshotExtractor.update_extractor_status(extractor.id, %{status: 1}) do
      {:ok, _extractor} ->
        send_mail_start(Application.get_env(:extractor, :send_emails_for_extractor))
        Dropbox.mkdir! %Dropbox.Client{access_token: System.get_env["DROP_BOX_TOKEN"]}, "Construction/#{camera_exid}/#{extractor.id}"
      _ ->
        IO.inspect "Status update failed!"
    end

    1..total_days |> Enum.reduce(start_date, fn _i, acc ->
      day_of_week = acc |> Calendar.Date.day_of_week_name
      rec_head = get_head_tail(schedule[day_of_week])
      rec_head |> Enum.each(fn(x) ->
        iterate(x, acc, timezone) |> download(camera_exid, interval, extractor.id, agent)
      end)
      acc |> Calendar.DateTime.to_erl |> Calendar.DateTime.from_erl!(timezone, {123456, 6}) |> Calendar.DateTime.add!(86400)
    end)

    count =
    Agent.get(agent, fn list -> list end)
    |> Enum.filter(fn(item) -> item end)
    |> Enum.count

    case SnapshotExtractor.update_extractor_status(extractor.id, %{status: 2, notes: "total images = #{count}"}) do
      {:ok, _} -> send_mail_end(Application.get_env(:extractor, :send_emails_for_extractor), count, extractor.camera_name)
      _ -> IO.inspect "Status update failed!"
    end
  end

  defp get_head_tail([]), do: []
  defp get_head_tail([head|tail]) do
    [[head]|get_head_tail(tail)]
  end

  def download([], _camera_exid, _interval, _id, _agent), do: IO.inspect "I am empty!"
  def download([starting, ending], camera_exid, interval, id, agent) do
    do_loop(starting, ending, interval, camera_exid, id, agent)
  end

  defp do_loop(starting, ending, _interval, _camera_exid, _id, _agent) when starting >= ending, do: IO.inspect "We are finished!"
  defp do_loop(starting, ending, interval, camera_exid, id, agent) do
    url = "#{System.get_env["EVERCAM_URL"]}/#{camera_exid}/recordings/snapshots/#{starting}?with_data=true&range=2&api_id=#{System.get_env["USER_ID"]}&api_key=#{System.get_env["USER_KEY"]}&notes=Evercam+Proxy"
    case HTTPoison.get(url, [], []) do
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        IO.inspect "Nothing found adding 1 seconds to date"
        do_loop(starting + 1, ending, interval, camera_exid, id, agent)
      {:ok, response} ->
        upload(response.status_code, response.body, starting, camera_exid, id, agent)
        do_loop(starting + interval, ending, interval, camera_exid, id, agent)
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.inspect "Media: #{reason}!"
        :timer.sleep(:timer.seconds(3))
        do_loop(starting, ending, interval, camera_exid, id, agent)
    end
  end

  def upload(200, response, starting, camera_exid, id, agent) do
    image = response |> Poison.decode! |> Map.get("snapshots") |> List.first
    data = decode_image(image["data"])
    IO.inspect data
    File.write("image.jpg", data, [:binary])
    IO.inspect "writing"
    case Dropbox.upload_file! %Dropbox.Client{access_token: System.get_env["DROP_BOX_TOKEN"]}, "image.jpg", "Construction/#{camera_exid}/#{id}/#{starting}.jpg" do
      {:skipping, reason} ->
        IO.inspect reason
        :timer.sleep(:timer.seconds(3))
        upload(200, response, starting, camera_exid, id, agent)
      _ ->
        Agent.update(agent, fn list -> ["true" | list] end)
        IO.inspect "written"
    end
  end
  def upload(_, response, _starting, _camera_exid, _id, _agent), do: IO.inspect "Not an Image! #{response}"

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

  defp send_mail_start(false), do: IO.inspect "We are in Development Mode!"
  defp send_mail_start(true), do: Extractor.ExtractMailer.extractor_started

  defp send_mail_end(false, _count, _camera_name), do: IO.inspect "We are in Development Mode!"
  defp send_mail_end(true, count, camera_name), do: Extractor.ExtractMailer.extractor_completed(count, camera_name)
end