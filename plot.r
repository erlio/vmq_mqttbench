#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)

packages.to.install <- c("grid", "ggplot2")

for (p in packages.to.install)
{
    print(p)
    if (suppressWarnings(!require(p, character.only = TRUE))) {
        install.packages(p, repos = "http://lib.stat.cmu.edu/R/CRAN")
        library(p, character.only=TRUE)
    }
}

if (length(args)==0) {
   infile = "bench.csv"
   outfile = "bench.png"
} else if (length(args)==2) {
  # default output file
   infile = args[1]
   outfile = args[2]
} else {
  stop("Wrong number of arguments.n", call.=FALSE)
}

png(file = outfile, width = 1200, height = 800)

dat <- read.csv(infile)
init_ts = dat$timestamp[1]
dat$ts = dat$timestamp - init_ts
bench_plot <- ggplot(dat, aes(x = ts)) +
                labs(x = "Elapsed Seconds", y = "") +
                theme(legend.title=element_blank())

plot1 <- bench_plot + labs(title = "Publisher and Consumer Rates (MQTT Publish/sec)") +
            geom_smooth(aes(y = publish_rate, color = "Publisher Rate"), size=0.5) +

            geom_smooth(aes(y = consume_rate, color = "Consumer Rate"), size=0.5) 

plot2 <- bench_plot + labs(title = "Nr. of Clients") +
            geom_line(aes(y = num_instances, color = "Nr of Clients"))


plot3 <- bench_plot + labs(title = "End-to-End Latencies in μs (Percentiles, Avg, Median, calculated over 10s sliding window)") +
            geom_line(aes(y = arithmetic_mean, color = "mean"), size=0.5) +
            geom_line(aes(y = perc_50, color = "median"), size=0.5) +
            geom_line(aes(y = perc_75, color = "75%"), size=0.5) +
            geom_line(aes(y = perc_95, color = "95%"), size=0.5) +
            geom_line(aes(y = perc_99, color = "99%"), size=0.5) +
            geom_line(aes(y = perc_999, color = "99.9%"), size=0.5)


pushViewport(viewport(layout = grid.layout(3, 1, heights=c(1.0, 1.0, 2.0))))
vplayout <- function(x,y) viewport(layout.pos.row = x, layout.pos.col = y)

print(plot1, vp=vplayout(1,1))
print(plot2, vp=vplayout(2,1))
print(plot3, vp=vplayout(3,1))
dev.off()
